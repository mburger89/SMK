// Non-inline Cortex-M core-intrinsic shims for the STM32F4 build — the
// things ports/stm32f4/*.swift needs but Embedded Swift cannot express
// (no inline assembly, and CMSIS's own helpers are `__STATIC_INLINE`
// `asm volatile` wrappers with no real symbol for @_extern(c, ...) to bind
// to). Same file, same name, same purpose as
// ports/stm32wb/platform/cortex_m_intrinsics.c; the RP2040 port's
// platform/flash_irq_wrappers.c and platform/gpio_init_wrappers.c are the
// same pattern applied to pico-sdk's static inlines.

#include "stm32f4xx.h"

// Opaque no-op called from inside every hardware-polling busy-wait loop in
// ports/stm32f4/ClockInit.swift.
//
// Why it exists (a real bug this fixed, found by disassembling the built
// binary — not a theoretical concern): Swift's
// `UnsafeMutablePointer<UInt32>.pointee` is NOT a volatile access. A loop
// like `while (reg.pointee & bit) == 0 {}` therefore looks loop-invariant to
// LLVM, which deletes it outright under the forward-progress rule — leaving
// smk_clock_init() as straight-line register writes with zero actual
// waiting (SYSCLK switched to a PLL that has not locked, flash latency
// applied before the regulator has reached the target voltage scale, ...).
//
// A call to an external C function the optimizer cannot see through defeats
// that: it may clobber arbitrary memory, so the register load must be
// re-issued on every iteration and the loop must be kept. Deliberately
// declared on the Swift side via @_extern(c, "smk_cpu_nop") — the whole
// point is that swiftc only ever sees the declaration, never the body.
void smk_cpu_nop(void) {
    __NOP();
}

// Minimal nrfx_glue.h for the SMK nRF52840 build's TinyUSB device-controller
// driver (ports/nrf52840/platform's TinyUSB glue pulls in TinyUSB's
// dcd_nrf5x.c, which #includes nrfx's clock driver headers — nrfx expects
// the *integrating app*, not the vendored SDK, to supply this file).
//
// nRF5_SDK ships two candidates, neither usable as-is for this build-only
// pass:
//   - modules/nrfx/templates/nrfx_glue.h: every macro is an unfilled
//     placeholder (empty body), which compiles fine as a statement but not
//     as the expression nrfx_power_clock.h uses it in
//     (`if (!NRFX_IRQ_IS_ENABLED(...))`) — a hard compile error, not a
//     runtime-behavior gap.
//   - integration/nrfx/nrfx_glue.h: fully-featured, but pulls in
//     app_util_platform.h/sdk_errors.h/sdk_resources.h and friends — SDK
//     components this port hasn't vendored (no app_error/log/nordic_common
//     wiring yet), a much bigger dependency pull than this task's TinyUSB-
//     only scope needs.
//
// So this file hand-rolls just enough for the clock driver to compile,
// using CMSIS NVIC intrinsics directly (already available via nrf.h from
// NRF5_MDK, unconditionally included by this build) instead of pulling in
// either SDK alternative above. IRQ macros are real (NVIC_*), not stubs;
// only the critical-section pair is a no-op, which is fine for now — this
// build has no RTOS/interrupt-driven concurrency yet (see
// platform_glue.c's vTaskDelay comment), same build-only caveat already
// flagged for VBUS/clock init generally (see CMakeLists.txt's note on
// dcd_nrf5x.c, and the design doc's Task 8 follow-up).
//
// nrfx's atomic (NRFX_ATOMIC_*) and custom-error-code hooks are
// deliberately omitted: nothing this build actually compiles (just the
// clock driver, transitively via dcd_nrf5x.c) references them, and leaving
// them out lets nrfx fall back to its own self-contained defaults
// (nrfx_error.h) rather than requiring us to either vendor nrfx_atomic.c or
// fake an incomplete atomic implementation.

#ifndef NRFX_GLUE_H__
#define NRFX_GLUE_H__

#ifdef __cplusplus
extern "C" {
#endif

#include <soc/nrfx_irqs.h>
#include <stdbool.h>
#include <stdint.h>

#define NRFX_ASSERT(expression)
#define NRFX_STATIC_ASSERT(expression) _Static_assert(expression, "nrfx static assert")

#define NRFX_IRQ_PRIORITY_SET(irq_number, priority) NVIC_SetPriority((irq_number), (priority))
#define NRFX_IRQ_ENABLE(irq_number)                 NVIC_EnableIRQ(irq_number)
#define NRFX_IRQ_IS_ENABLED(irq_number) \
    (0 != (NVIC->ISER[(uint32_t)(irq_number) / 32] & (1UL << ((uint32_t)(irq_number) % 32))))
#define NRFX_IRQ_DISABLE(irq_number)       NVIC_DisableIRQ(irq_number)
#define NRFX_IRQ_PENDING_SET(irq_number)   NVIC_SetPendingIRQ(irq_number)
#define NRFX_IRQ_PENDING_CLEAR(irq_number) NVIC_ClearPendingIRQ(irq_number)
#define NRFX_IRQ_IS_PENDING(irq_number)    (NVIC_GetPendingIRQ(irq_number) == 1)

// No RTOS/IRQ-driven concurrency yet in this build-only pass — see header
// comment above.
#define NRFX_CRITICAL_SECTION_ENTER()
#define NRFX_CRITICAL_SECTION_EXIT()

#define NRFX_DELAY_DWT_BASED 0
#include <soc/nrfx_coredep.h>
#define NRFX_DELAY_US(us_time) nrfx_coredep_delay_us(us_time)

#ifdef __cplusplus
}
#endif

#endif // NRFX_GLUE_H__

// Narrow C remainder for smk_kbd_rp2040's BLE UART transport — see
// BleHidKbdUart.swift for the full reasoning and the rest of the port.
// Everything in this file is here because pico-sdk exposes it in a form
// Swift cannot bind to directly (static-inline functions with no linkable
// symbol, a `#define` macro rather than a real global, or a
// vendor-internal struct too fragile to mirror) — every genuinely callable
// piece of logic lives in Swift instead. The btstack_uart_block_t vtable
// that used to be section 1 of this file is now a verified Swift mirror in
// BleHidKbdUart.swift (BtstackUartVtable), populated with the Swift
// callback functions directly.
//
// 1. async_context_poll_t (pico/async_context_poll.h) is genuinely the
//    highest-complexity struct this port touches, confirmed by reading the
//    real headers: it's `{ async_context_t core; semaphore_t sem; }`,
//    where async_context_t itself embeds a `const async_context_type_t
//    *type` vtable pointer (13 function-pointer fields covering
//    lock/timer/worker/poll/wait machinery), two intrusive linked-list
//    head pointers, an absolute_time_t, and flags/core_num — and
//    semaphore_t embeds pico-sdk's `lock_core` (a spinlock pointer plus
//    debug-owner bookkeeping) alongside its own counters. This is the
//    documented mirror-fallback case (a vendor-internal, version-fragile
//    layout that can't be pinned down confidently), kept here and exposed
//    to Swift as two scalar functions.
//
// 2. bt_uart_instance() exists because pico-sdk's `uart1` is NOT a real
//    linkable global: `hardware/uart.h` defines it as
//    `#define uart1 ((uart_inst_t *)uart1_hw)` — a macro, not a symbol —
//    so there is no C-linkage name for a Swift `@_extern(c, "uart1")` to
//    bind to at all (confirmed by grepping the real header; this wasn't a
//    judgment call). This one-line accessor is the only way to hand the
//    resolved pointer to Swift.
//
// 3. smk_uart_write_blocking / smk_uart_is_readable / smk_uart_getc /
//    smk_uart_set_hw_flow: uart_write_blocking, uart_is_readable,
//    uart_getc, and uart_set_hw_flow are ALL declared `static inline` in
//    hardware/uart.h — no linkable symbol exists for Swift to bind to,
//    same class of problem gpio_init_wrappers.c already solved for
//    gpio_set_dir/gpio_put/gpio_pull_up/gpio_pull_down. These thin
//    non-inline wrappers follow that exact established pattern.

#include <stdint.h>
#include <stddef.h>

#include "hardware/uart.h"
#include "pico/async_context_poll.h"
#include "pico/btstack_run_loop_async_context.h"

// --- 1. async_context_poll_t state ------------------------------------------

static async_context_poll_t s_async_ctx;

void *smk_async_context_setup(void) {
    async_context_poll_init_with_defaults(&s_async_ctx);
    return (void *) btstack_run_loop_async_context_get_instance(&s_async_ctx.core);
}

void smk_async_context_poll(void) {
    async_context_poll(&s_async_ctx.core);
}

// --- 2. uart1 accessor -------------------------------------------------------

void *bt_uart_instance(void) {
    return (void *) uart1;
}

// --- 3. static-inline pico-sdk UART wrappers --------------------------------

void smk_uart_set_hw_flow(uart_inst_t *uart, bool cts, bool rts) {
    uart_set_hw_flow(uart, cts, rts);
}

void smk_uart_write_blocking(uart_inst_t *uart, const uint8_t *src, size_t len) {
    uart_write_blocking(uart, src, len);
}

bool smk_uart_is_readable(uart_inst_t *uart) {
    return uart_is_readable(uart);
}

uint8_t smk_uart_getc(uart_inst_t *uart) {
    return (uint8_t) uart_getc(uart);
}

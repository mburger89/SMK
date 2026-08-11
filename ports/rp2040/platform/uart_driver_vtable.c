// Narrow C remainder for smk_kbd_rp2040's BLE UART transport — see
// BleHidKbdUart.swift for the full reasoning and the rest of the port.
// Everything in this file was needed because pico-sdk/BTstack expose it
// in a form Swift cannot bind to directly (a struct literal BTstack reads
// by address, static-inline functions with no linkable symbol, or a
// `#define` macro rather than a real global) — every genuinely callable
// piece of logic lives in Swift instead.
//
// 1. btstack_uart_block_t (== btstack_uart_t, see btstack_uart.h) is a
//    struct-of-function-pointers BTstack expects by address. The struct
//    literal itself must stay C, but every callback body it points to is a
//    Swift @_cdecl function (BleHidKbdUart.swift) referenced here by
//    C-linkage symbol name. Verified against the real vendored struct
//    (~/pico-sdk/lib/btstack/src/btstack_uart.h): it actually has 17
//    fields, not 10 — the 7 extra (get_supported_sleep_modes/set_sleep/
//    set_wakeup_handler/set_frame_received/set_frame_sent/receive_frame/
//    send_frame) are for BTstack's frame-based/sleep-capable transports,
//    unused by this plain-H4-over-UART transport. Leaving them out of the
//    designated-initializer literal below zero-initializes them (NULL),
//    exactly matching the deleted C file's own `uart_driver` literal.
//
// 2. async_context_poll_t (pico/async_context_poll.h) is genuinely the
//    highest-complexity struct touched by this whole plan, confirmed by
//    reading the real headers: it's `{ async_context_t core; semaphore_t
//    sem; }`, where async_context_t itself embeds a `const
//    async_context_type_t *type` vtable pointer (13 function-pointer
//    fields covering lock/timer/worker/poll/wait machinery), two intrusive
//    linked-list head pointers, an absolute_time_t, and flags/core_num —
//    and semaphore_t embeds pico-sdk's `lock_core` (a spinlock pointer plus
//    debug-owner bookkeeping) alongside its own counters. Hand-rolling this
//    in Swift would mean mirroring a vendor-internal, version-fragile
//    layout for zero real benefit — kept here exactly as the plan directed,
//    exposed to Swift as two scalar functions.
//
// 3. bt_uart_instance() exists because pico-sdk's `uart1` is NOT a real
//    linkable global: `hardware/uart.h` defines it as
//    `#define uart1 ((uart_inst_t *)uart1_hw)` — a macro, not a symbol —
//    so there is no C-linkage name for a Swift `@_extern(c, "uart1")` to
//    bind to at all (confirmed by grepping the real header; this wasn't a
//    judgment call). This one-line accessor is the only way to hand the
//    resolved pointer to Swift.
//
// 4. smk_uart_write_blocking / smk_uart_is_readable / smk_uart_getc /
//    smk_uart_set_hw_flow: uart_write_blocking, uart_is_readable,
//    uart_getc, and uart_set_hw_flow are ALL declared `static inline` in
//    hardware/uart.h (confirmed against the real header, contrary to this
//    task's plan, which assumed they were plain externs) — no linkable
//    symbol exists for Swift to bind to, same class of problem
//    gpio_init_wrappers.c already solved for gpio_set_dir/gpio_put/
//    gpio_pull_up/gpio_pull_down. These thin non-inline wrappers follow
//    that exact established pattern.

#include <stdint.h>
#include <stddef.h>

#include "hardware/uart.h"
#include "btstack_uart_block.h"
#include "pico/async_context_poll.h"
#include "pico/btstack_run_loop_async_context.h"

// --- 1. btstack_uart_block_t vtable ----------------------------------------

// Declared in BleHidKbdUart.swift as @_cdecl functions with these exact
// names/signatures — verified field-for-field against the real
// btstack_uart_t (btstack_uart.h): int(*init)(const btstack_uart_config_t*),
// int(*open)(void), int(*close)(void),
// void(*set_block_received)(void(*)(void)),
// void(*set_block_sent)(void(*)(void)), int(*set_baudrate)(uint32_t),
// int(*set_parity)(int), int(*set_flowcontrol)(int),
// void(*receive_block)(uint8_t*,uint16_t),
// void(*send_block)(const uint8_t*,uint16_t).
extern int uart_driver_init(const btstack_uart_config_t *config);
extern int uart_driver_open(void);
extern int uart_driver_close(void);
extern void uart_driver_set_block_received(void (*block_handler)(void));
extern void uart_driver_set_block_sent(void (*block_handler)(void));
extern int uart_driver_set_baudrate(uint32_t baudrate);
extern int uart_driver_set_parity(int parity);
extern int uart_driver_set_flowcontrol(int flowcontrol);
extern void uart_driver_receive_block(uint8_t *buffer, uint16_t len);
extern void uart_driver_send_block(const uint8_t *buffer, uint16_t length);

// BleHidKbdUart.swift takes this struct's ADDRESS from Swift (needed as
// hci_transport_h4_instance()'s argument) via a scalar-placeholder
// `@_extern(c, "smk_uart_driver") var smk_uart_driver: UInt8` +
// `withUnsafePointer(to:)` — empirically verified (standalone probe, then
// re-confirmed against this exact struct's real address in the linked
// smk_kbd_rp2040 binary) to produce a correct address-of, not a
// dereference. If a future toolchain ever changes that codegen behavior,
// the brief's documented fallback is a one-line C accessor here:
//   const btstack_uart_block_t *smk_uart_driver_ptr(void) { return &smk_uart_driver; }
// — swap the Swift side to call that instead of taking the extern var's
// address; no other change needed.
const btstack_uart_block_t smk_uart_driver = {
    .init = &uart_driver_init,
    .open = &uart_driver_open,
    .close = &uart_driver_close,
    .set_block_received = &uart_driver_set_block_received,
    .set_block_sent = &uart_driver_set_block_sent,
    .set_baudrate = &uart_driver_set_baudrate,
    .set_parity = &uart_driver_set_parity,
    .set_flowcontrol = &uart_driver_set_flowcontrol,
    .receive_block = &uart_driver_receive_block,
    .send_block = &uart_driver_send_block,
};

// --- 2. async_context_poll_t state ------------------------------------------

static async_context_poll_t s_async_ctx;

void *smk_async_context_setup(void) {
    async_context_poll_init_with_defaults(&s_async_ctx);
    return (void *) btstack_run_loop_async_context_get_instance(&s_async_ctx.core);
}

void smk_async_context_poll(void) {
    async_context_poll(&s_async_ctx.core);
}

// --- 3. uart1 accessor -------------------------------------------------------

void *bt_uart_instance(void) {
    return (void *) uart1;
}

// --- 4. static-inline pico-sdk UART wrappers --------------------------------

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

// MPSL (Multiprotocol Service Layer) bring-up — required by the
// SoftDevice Controller (see BleHidSdc.swift/ble_hid_sdc.c, Task 7).
// Vendored API from ${NRFXLIB_PATH}/mpsl/include/mpsl.h. This project has
// no other radio protocol running (no Timeslot API use, no coexistence),
// so MPSL's role here is purely "provide RADIO/RTC0/timer scheduling for
// SDC."
//
// IRQn_Type values below are raw Int32s mirroring the vendored
// nrf52840.h's enum (Embedded Swift doesn't import that C enum here,
// matching this project's established @_extern(c)-only C interop style —
// see e.g. Sources/smk/GPIOInit.swift's GPIO_MODE_INPUT/OUTPUT constants
// for the same pattern) — verified directly against
// ~/nRF5_SDK/modules/nrfx/mdk/nrf52840.h during this task (POWER_CLOCK_IRQn
// = 0, RADIO_IRQn = 1, SWI0_EGU0_IRQn = 20 — all match the plan's claimed
// values exactly).
private let powerClockIRQn: Int32 = 0
private let radioIRQn: Int32 = 1
// An otherwise-unused peripheral IRQ, per MPSL's "low_prio_irq" contract
// (nrfxlib/mpsl/doc/mpsl.rst): any IRQ not already claimed by a real
// peripheral this board uses. SWI0_EGU0 (Software Interrupt 0 / Event
// Generator Unit 0) is the conventional choice — unused on this board,
// matching nRF Connect SDK's own default for CONFIG_MPSL_LOW_PRIO_IRQN.
private let mpslLowPrioIRQn: Int32 = 20

// mpsl_init's real signature (verified against
// ~/sdk-nrfxlib/mpsl/include/mpsl.h during this task):
//   int32_t mpsl_init(mpsl_clock_lfclk_cfg_t const *p_clock_config,
//                      IRQn_Type low_prio_irq,
//                      mpsl_assert_handler_t p_assert_handler);
// matches the plan's claimed shape (return type, assert-handler typedef
// `void (*)(const char * const, uint32_t)`) — the only difference is the
// first parameter's real type is a pointer to a clock-config struct rather
// than `void *`, which doesn't matter here since we always pass nil and
// Swift's @_extern(c) declares call-site ABI, not a header-checked
// prototype (same reasoning as GPIO_MODE_INPUT/OUTPUT's raw-Int32 style
// above). IRQn_Type itself is a plain C enum (4-byte, matching Int32) per
// nrf52840.h.
@_extern(c, "mpsl_init")
func mpsl_init(_ clockConfig: UnsafeRawPointer?, _ lowPrioIRQ: Int32, _ assertHandler: @convention(c) (UnsafePointer<CChar>?, UInt32) -> Void) -> Int32

@_extern(c, "mpsl_low_priority_process")
func mpsl_low_priority_process()

@_extern(c, "MPSL_IRQ_CLOCK_Handler")
func MPSL_IRQ_CLOCK_Handler()

// --- NVIC register access ---------------------------------------------
//
// DEVIATION FROM PLAN: the plan called for `@_extern(c, "NVIC_SetPriority")`
// / `@_extern(c, "NVIC_EnableIRQ")`. Verified against
// ~/nRF5_SDK/components/toolchain/cmsis/include/core_cm4.h during this
// task: both are CMSIS `__STATIC_INLINE` functions (expands to plain C
// `static inline`), which — like Task 4's tusb_init()/tud_task() macros/
// inlines (see UsbHid.swift's header comment) — have no real,
// externally-linkable symbol for @_extern(c, ...) to bind to. A Swift
// build declaring them that way would fail at link time with an undefined
// reference.
//
// Unlike Task 4's TinyUSB case (where the inline bodies call other real
// exported functions), NVIC_SetPriority/EnableIRQ's bodies are themselves
// just 1-2 raw register pokes into the ARMv7-M NVIC block — the same kind
// of direct MMIO access this port's own GPIORegisters.swift already does
// for P0. So instead of adding a throwaway C wrapper, they're reimplemented
// here directly as Swift register writes, verified against
// core_cm4.h's NVIC_Type layout and __NVIC_SetPriority/__NVIC_EnableIRQ
// bodies:
//   NVIC_BASE = 0xE000E100 (SCS_BASE 0xE000E000 + 0x0100)
//   ISER[8]   @ offset 0x000 (word array, one bit per IRQ)
//   IP[240]   @ offset 0x300 (byte array, one byte per IRQ)
//   __NVIC_PRIO_BITS = 3 for nRF52840 (nrf52840.h), so priority is left-
//   shifted by (8 - 3) = 5 bits into the top of the priority byte, same as
//   __NVIC_SetPriority's body.
// Only the IRQn >= 0 (device-specific interrupt) path is implemented —
// the only case this glue ever calls (radioIRQn=1, mpslLowPrioIRQn=20);
// __NVIC_SetPriority's negative-IRQn (system exception, via SCB->SHP)
// branch is intentionally not ported since nothing here needs it.
private let nvicISER0 = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0xE000_E100 as UInt32))!
private let nvicIPBase = UnsafeMutablePointer<UInt8>(bitPattern: UInt(0xE000_E400 as UInt32))!

private func nvicEnableIRQ(_ irqn: Int32) {
    guard irqn >= 0 else { return }
    let n = UInt32(irqn)
    nvicISER0.advanced(by: Int(n >> 5)).pointee = UInt32(1) << (n & 0x1F)
}

private func nvicSetPriority(_ irqn: Int32, _ priority: UInt32) {
    guard irqn >= 0 else { return }
    nvicIPBase.advanced(by: Int(irqn)).pointee = UInt8(truncatingIfNeeded: priority << (8 - 3))
}

@_cdecl("smk_mpsl_assert_handler")
func smk_mpsl_assert_handler(_ file: UnsafePointer<CChar>?, _ line: UInt32) {
    while true {}
}

@_cdecl("mpsl_glue_init")
func mpsl_glue_init() {
    // nil clock config = default RC low-frequency clock source (per
    // mpsl_init's doc comment). A real crystal LFCLK config improves BLE
    // timing accuracy/power but isn't needed to link/boot — deferred to
    // hardware bring-up, matching this plan's build-only scope.
    let err = mpsl_init(nil, mpslLowPrioIRQn, smk_mpsl_assert_handler)
    if err != 0 {
        while true {} // fatal — nothing meaningful to do without MPSL
    }

    nvicSetPriority(radioIRQn, 0) // MPSL_HIGH_IRQ_PRIORITY, per mpsl.rst
    nvicEnableIRQ(radioIRQn)

    nvicSetPriority(mpslLowPrioIRQn, 5) // lower priority (higher number) than RADIO, per mpsl.rst
    nvicEnableIRQ(mpslLowPrioIRQn)
}

// RADIO/RTC0/TIMER0 interrupt handlers are provided by MPSL itself
// (reserved instances, per mpsl.rst — "must not be reconfigured while
// MPSL is enabled"); no application-side handler needed for those beyond
// the nvicEnableIRQ(radioIRQn) above (RTC0's is auto-enabled by
// mpsl_init). POWER_CLOCK is NOT auto-enabled and needs an explicit
// application-provided handler forwarding to MPSL — same @_cdecl
// mechanism app_main_swift uses to be found by name, here found by the
// vector table in gcc_startup_nrf52840.S instead of C's main().
@_cdecl("POWER_CLOCK_IRQHandler")
func POWER_CLOCK_IRQHandler() {
    MPSL_IRQ_CLOCK_Handler()
    // Task 8 note: TinyUSB's dcd_nrf5x.c also needs POWER_CLOCK events
    // (VBUS detect) — this handler will need to also call TinyUSB's power
    // event forwarding once that wiring is finalized in Task 8.
}

// Application must call this promptly (per mpsl.rst, "within a couple of
// ms") whenever mpslLowPrioIRQn fires. Wired from platform_glue.c's
// vTaskDelay shim (called every scan tick, same as kb_usb_task()) rather
// than from the ISR itself — matches this project's existing
// poll-from-the-cooperative-loop style (see ble_kbd_uart_poll() in
// ports/rp2040/platform/ble_hid_kbd_uart.c for the RP2040 equivalent
// pattern).
@_cdecl("mpsl_glue_poll")
func mpsl_glue_poll() {
    mpsl_low_priority_process()
}

@_cdecl("SWI0_EGU0_IRQHandler")
func SWI0_EGU0_IRQHandler() {
    // Intentionally empty — mpsl_glue_poll() is called unconditionally
    // from the main loop every tick rather than gated on this ISR firing,
    // simplest correct thing without hardware in hand to tune polling
    // latency against. Revisit if hardware testing shows this needs to be
    // interrupt-driven instead.
}

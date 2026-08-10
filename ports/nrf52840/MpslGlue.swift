// MPSL (Multiprotocol Service Layer) bring-up — required by the
// SoftDevice Controller (see platform/ble_hid_sdc.c, Task 7 — that task
// stayed in C rather than adding a BleHidSdc.swift, per its own documented
// exception).
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

@_extern(c, "MPSL_IRQ_RADIO_Handler")
func MPSL_IRQ_RADIO_Handler()

@_extern(c, "MPSL_IRQ_RTC0_Handler")
func MPSL_IRQ_RTC0_Handler()

@_extern(c, "MPSL_IRQ_TIMER0_Handler")
func MPSL_IRQ_TIMER0_Handler()

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

// --- USB VBUS power event forwarding (Task 8 Step 1) -------------------
//
// Task 5's note above (on POWER_CLOCK_IRQHandler) said TinyUSB's
// dcd_nrf5x.c "also needs POWER_CLOCK events." Verified for real against
// ~/tinyusb/src/portable/nordic/nrf5x/dcd_nrf5x.c: it does NOT register
// its own POWER_CLOCK handler and has no `tusb_int_handler`-style entry
// point for the raw IRQ. Instead it exposes
// `void tusb_hal_nrf_power_event(uint32_t event)` (event = 0 DETECTED /
// 1 REMOVED / 2 READY, "chosen to be as same as NRFX_POWER_USB_EVT_* in
// nrfx_power.h" per its own header comment) and documents that *the
// application* must call it, sourced either from Nordic's nrfx_power
// driver (non-SoftDevice apps) or from classic-SoftDevice SOC events
// (SOFTDEVICE_PRESENT apps) — see ~/tinyusb/hw/bsp/nrf/family.c's
// board_init()/power_event_handler()/proc_soc() for both reference
// shapes. Neither applies verbatim here: this build doesn't compile
// nrfx_power.c (no CMake wiring for it, and pulling it in would also
// require nrfx_config.h's NRFX_POWER_ENABLED/NRFX_CLOCK_ENABLED knobs,
// which ports/nrf52840/platform/nrfx_glue.h + CMakeLists.txt's nrfx
// include-dir comment don't currently turn on), and it doesn't use the
// classic monolithic SoftDevice at all (Task 6/7 use nrfxlib's
// SoftDevice *Controller*, a header-only-linked component with no SOC-
// event mechanism). So instead of vendoring nrfx_power.c, this reads/
// clears the 3 relevant NRF_POWER event registers directly — same raw-
// MMIO style as the NVIC access above, and as NRF_RNG access in
// ble_hid_sdc.c's sdc_rand_poll() (Task 7) — verified against
// nrf52840.h's POWER_Type layout (base 0x40000000):
//   EVENTS_USBDETECTED @ 0x11C, EVENTS_USBREMOVED @ 0x120,
//   EVENTS_USBPWRRDY @ 0x124, INTENSET @ 0x304, USBREGSTATUS @ 0x438
//   (VBUSDETECT = bit 0, OUTPUTRDY = bit 1); INTENSET bit positions for
//   USBDETECTED/USBREMOVED/USBPWRRDY are 7/8/9 (nrf52840_bitfields.h).
//
// NOTE: POWER and CLOCK are the same physical peripheral/IRQ sharing one
// register block (NRF_POWER_BASE == NRF_CLOCK_BASE == 0x40000000, and
// both structs place INTENSET at the same 0x304 offset) — MPSL's
// mpsl_init() already sets its own CLOCK-side INTENSET bits (HFCLKSTARTED
// etc.) on this same register. INTENSET on nRF52 is write-1-to-set /
// write-0-is-no-op (never a plain read-modify-write), so ORing in just
// the USB bits below cannot clobber MPSL's bits regardless of init order.
private let powerBase = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0x4000_0000 as UInt32))!
private let powerEventsUSBDetected = powerBase.advanced(by: 0x11C / 4)
private let powerEventsUSBRemoved = powerBase.advanced(by: 0x120 / 4)
private let powerEventsUSBPwrRdy = powerBase.advanced(by: 0x124 / 4)
private let powerIntenSet = powerBase.advanced(by: 0x304 / 4)
private let powerUSBRegStatus = powerBase.advanced(by: 0x438 / 4)

private let powerIntenUSBDetectedMsk: UInt32 = 1 << 7
private let powerIntenUSBRemovedMsk: UInt32 = 1 << 8
private let powerIntenUSBPwrRdyMsk: UInt32 = 1 << 9
private let powerUSBRegVbusDetectMsk: UInt32 = 1 << 0
private let powerUSBRegOutputRdyMsk: UInt32 = 1 << 1

// dcd_nrf5x.c's tusb_hal_nrf_power_event event codes (see comment above).
private let usbEvtDetected: UInt32 = 0
private let usbEvtRemoved: UInt32 = 1
private let usbEvtReady: UInt32 = 2

@_extern(c, "tusb_hal_nrf_power_event")
func tusb_hal_nrf_power_event(_ event: UInt32)

// Enables the USB power interrupt sources and seeds TinyUSB's state
// machine from whatever VBUS/regulator state already exists at boot
// (mirrors family.c's board_init(): "USB power may already be ready at
// this time -> no event generated, we need to invoke the handler based
// on the status initially"). Called from mpsl_glue_init() below, which
// platform_glue.c's main() runs before app_main_swift() (and therefore
// before UsbHid.swift's init_wired_link() / tusb_rhport_init()) — same
// ordering as family.c's board_init() running before tusb_init().
private func smkUsbPowerInit() {
    powerIntenSet.pointee = powerIntenUSBDetectedMsk | powerIntenUSBRemovedMsk | powerIntenUSBPwrRdyMsk

    let status = powerUSBRegStatus.pointee
    if status & powerUSBRegVbusDetectMsk != 0 {
        tusb_hal_nrf_power_event(usbEvtDetected)
    }
    if status & powerUSBRegOutputRdyMsk != 0 {
        tusb_hal_nrf_power_event(usbEvtReady)
    }
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

    // POWER_CLOCK_IRQn itself needs no explicit nvicEnableIRQ call here:
    // per mpsl.rst, "MPSL enables interrupts for the reserved instances,
    // as well as for POWER_CLOCK and low_prio_irq" — mpsl_init() above
    // already did it, same as RADIO/RTC0/TIMER0's "reserved instances"
    // auto-enable. Only the USB-specific event *source* bits (INTENSET)
    // need enabling here, since MPSL only cares about CLOCK's own bits.
    smkUsbPowerInit()
}

// RADIO/RTC0/TIMER0 are "reserved instances" MPSL claims and auto-enables
// the NVIC line for internally as part of mpsl_init (per mpsl.rst) — but
// per mpsl.h's doc comments on MPSL_IRQ_RADIO_Handler/_RTC0_Handler/
// _TIMER0_Handler, each "should be placed in the interrupt vector table"
// by the application, same as MPSL_IRQ_CLOCK_Handler below. Without an
// application-provided forwarding handler, these vector-table slots (in
// gcc_startup_nrf52840.S) fall through to the weak Default_Handler
// (infinite loop) and hang the firmware the moment MPSL's internal
// scheduler first fires RTC0 — same @_cdecl mechanism app_main_swift uses
// to be found by name, here found by the vector table in
// gcc_startup_nrf52840.S instead of C's main().
@_cdecl("RADIO_IRQHandler")
func RADIO_IRQHandler() {
    MPSL_IRQ_RADIO_Handler()
}

@_cdecl("RTC0_IRQHandler")
func RTC0_IRQHandler() {
    MPSL_IRQ_RTC0_Handler()
}

@_cdecl("TIMER0_IRQHandler")
func TIMER0_IRQHandler() {
    MPSL_IRQ_TIMER0_Handler()
}

// POWER_CLOCK's NVIC line *is* auto-enabled by mpsl_init (per mpsl.rst,
// "MPSL enables interrupts for the reserved instances, as well as for
// POWER_CLOCK and low_prio_irq" — same as RADIO/RTC0/TIMER0 above; this
// corrects an earlier, inaccurate version of this comment from Task 5
// that claimed the opposite). Like those three, it still needs an
// explicit application-provided vector-table handler: mpsl.rst says "it
// is up to the application to forward any clock-related events to
// MPSL_IRQ_CLOCK_Handler... the application is free to forward all
// events for the POWER_CLOCK interrupt" (i.e. unconditionally, no need
// to filter by which event fired) — MPSL_IRQ_CLOCK_Handler() ignores
// events it doesn't care about.
//
// This interrupt line is shared with the POWER peripheral's USB VBUS
// events (see smkUsbPowerInit()/tusb_hal_nrf_power_event() above —
// Task 8 Step 1, resolving the note this comment used to end with).
// Order doesn't matter: MPSL's handler only touches CLOCK-side event
// registers, this only touches POWER-side ones (EVENTS_USBDETECTED/
// _USBREMOVED/_USBPWRRDY), so the two forwards are independent.
@_cdecl("POWER_CLOCK_IRQHandler")
func POWER_CLOCK_IRQHandler() {
    MPSL_IRQ_CLOCK_Handler()

    if powerEventsUSBDetected.pointee != 0 {
        powerEventsUSBDetected.pointee = 0 // write 0 clears an EVENTS_ register on nRF52
        tusb_hal_nrf_power_event(usbEvtDetected)
    }
    if powerEventsUSBRemoved.pointee != 0 {
        powerEventsUSBRemoved.pointee = 0
        tusb_hal_nrf_power_event(usbEvtRemoved)
    }
    if powerEventsUSBPwrRdy.pointee != 0 {
        powerEventsUSBPwrRdy.pointee = 0
        tusb_hal_nrf_power_event(usbEvtReady)
    }
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

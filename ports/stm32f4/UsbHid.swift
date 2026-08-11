// STM32F4 USB HID glue via TinyUSB's dwc2 driver (OTG_FS peripheral). The
// "wired" half of the SMK contract — this board has no BLE this pass.
//
// Real TinyUSB symbol names (not the macro/static-inline names): see this
// plan's Global Constraints — tusb_init/tud_task/tud_hid_ready/
// tud_hid_keyboard_report have no linkable C symbol; ports/nrf52840/UsbHid.swift
// already established (and verified against the vendored source) the real
// exported equivalents used below.

private let gpioaBase: UInt32 = 0x40020000
private let gpioaModer = UnsafeMutablePointer<UInt32>(bitPattern: UInt(gpioaBase + 0x00))!
private let gpioaAfrh = UnsafeMutablePointer<UInt32>(bitPattern: UInt(gpioaBase + 0x24))!

private let rccAhb1Enr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0x40023800 + 0x30))!
private let rccAhb2Enr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0x40023800 + 0x34))!
private let rccAhb1EnrGpioaEn: UInt32 = 1 << 0
private let rccAhb2EnrOtgfsEn: UInt32 = 1 << 7

private let afAlternateFunctionMode: UInt32 = 0b10
private let af10: UInt32 = 0b1010

// dwc2_clock_init() (TinyUSB's ports/synopsys/dwc2/dwc2_stm32.h) is a
// documented no-op on STM32 — this project's own equivalent of enabling the
// OTG_FS peripheral clock and muxing PA11/PA12 to AF10 (verified against
// that vendored header during this plan's research). Must run before
// init_wired_link() below.
private func enableUsbClockAndPins() {
    rccAhb1Enr.pointee |= rccAhb1EnrGpioaEn
    rccAhb2Enr.pointee |= rccAhb2EnrOtgfsEn

    // PA11 = D-, PA12 = D+, both alternate-function mode, AF10 (OTG_FS).
    let moderMask: UInt32 = (0b11 << 22) | (0b11 << 24)
    let moderValue: UInt32 = (afAlternateFunctionMode << 22) | (afAlternateFunctionMode << 24)
    gpioaModer.pointee = (gpioaModer.pointee & ~moderMask) | moderValue

    let afrhMask: UInt32 = (0b1111 << 12) | (0b1111 << 16)
    let afrhValue: UInt32 = (af10 << 12) | (af10 << 16)
    gpioaAfrh.pointee = (gpioaAfrh.pointee & ~afrhMask) | afrhValue
}

@_extern(c, "tusb_rhport_init")
func tusb_rhport_init(_ rhport: UInt8, _ rhInit: UnsafeRawPointer?) -> Bool

@_extern(c, "tud_task_ext")
func tud_task_ext(_ timeoutMs: UInt32, _ inIsr: Bool)

@_extern(c, "tud_hid_n_ready")
func tud_hid_n_ready(_ instance: UInt8) -> Bool

@_extern(c, "tud_hid_n_keyboard_report")
func tud_hid_n_keyboard_report(_ instance: UInt8, _ reportID: UInt8, _ modifier: UInt8, _ keycode: UnsafePointer<UInt8>) -> Bool

// Implemented in platform/usb_descriptors.c — crosses the Swift/C boundary,
// needs @_extern(c, ...), matching this file's own tud_*/tusb_* declarations.
@_extern(c, "smk_keymap_usb_service")
func smk_keymap_usb_service()

// OTG_FS interrupt forwarding: without this, OTG_FS_IRQHandler in the
// vector table (startup_stm32f411xe.s, CMSIS's default weak alias) falls
// through to Default_Handler (an infinite loop), and dwc2's dcd_init()
// (called via tusb_rhport_init below) unconditionally enables
// NVIC_EnableIRQ(OTG_FS_IRQn) (verified against the vendored dwc2_stm32.h's
// dwc2_dcd_int_enable). So the very first USB event after init_wired_link()
// runs would hang the firmware — same class of bug ports/nrf52840/UsbHid.swift's
// USBD_IRQHandler and MpslGlue.swift's interrupt forwarders fix for that
// port. `tusb_int_handler` is TinyUSB's real exported ISR body
// (src/tusb.c), verified directly against the vendored source.
@_extern(c, "tusb_int_handler")
func tusb_int_handler(_ rhport: UInt8, _ inIsr: Bool)

@_cdecl("OTG_FS_IRQHandler")
func OTG_FS_IRQHandler() {
    tusb_int_handler(0, true)
}

func init_wired_link() {
    enableUsbClockAndPins()
    _ = tusb_rhport_init(0, nil)
}

// Pump TinyUSB. Called every scan tick from platform_glue.c's vTaskDelay
// via its own `extern void kb_usb_task(void);` declaration — a real
// Swift/C boundary crossing, so @_cdecl (unlike init_wired_link/
// send_wired_report below, called only from Main.swift, plain Swift-to-
// Swift same-module resolution).
@_cdecl("kb_usb_task")
func kb_usb_task() {
    tud_task_ext(UInt32.max, false) // wait-forever, not-in-ISR
    smk_keymap_usb_service()
}

// Send a standard 8-byte boot-keyboard report: [modifier][reserved][6 keys].
func send_wired_report(_ modifier: UInt8, _ keys: UnsafePointer<UInt8>) {
    guard tud_hid_n_ready(0) else { return }
    _ = tud_hid_n_keyboard_report(0, 0, modifier, keys)
}

// TinyUSB requires this when CFG_TUSB_OS == OPT_OS_NONE (no RTOS) — same
// requirement ports/nrf52840/UsbHid.swift's tusb_time_millis_api already
// documents (verified against the vendored tusb.c). Uncalibrated per-call
// counter, NOT a real millisecond clock — no hardware timer wired up yet.
private var s_millisCounter: UInt32 = 0

@_cdecl("tusb_time_millis_api")
func tusb_time_millis_api() -> UInt32 {
    s_millisCounter &+= 1
    return s_millisCounter
}

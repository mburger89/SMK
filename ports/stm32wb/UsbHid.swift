// STM32WB USB HID glue via TinyUSB's fsdev driver (WB55's classic
// device-only "USB_FS" peripheral — the same fsdev family F0/F1/F3/L0/G0/G4
// use, NOT F4's dual FS/HS dwc2 OTG core). The "wired" half of the SMK
// contract for this board; BLE HID lands separately in Task 7.
//
// Real TinyUSB symbol names (not the macro/static-inline names) reused
// verbatim from ports/stm32f4/UsbHid.swift, which established (and verified
// against the vendored source) these are genuinely portable TinyUSB API,
// not F4/dwc2-specific: tusb_rhport_init/tud_task_ext/tud_hid_n_ready/
// tud_hid_n_keyboard_report/tusb_int_handler/tusb_time_millis_api.

// GPIOA: 0x4800_0000 (AHB2PERIPH_BASE + 0) on WB55 — differs from F4's
// GPIOA base (0x4002_0000, AHB1), confirmed via cmsis-device-wb's
// stm32wb55xx.h (`GPIOA_BASE == IOPORT_BASE == AHB2PERIBH_BASE + 0`,
// `AHB2PERIPH_BASE == PERIPH_BASE + 0x08000000UL`). Register layout
// (MODER at 0x00, AFRH at 0x24) is identical to F4's GPIO_TypeDef.
private let gpioaBase: UInt32 = 0x4800_0000
private let gpioaModer = UnsafeMutablePointer<UInt32>(bitPattern: UInt(gpioaBase + 0x00))!
private let gpioaAfrh = UnsafeMutablePointer<UInt32>(bitPattern: UInt(gpioaBase + 0x24))!

// RCC: base AHB4PERIPH_BASE (0x5800_0000) — same base ports/stm32wb/ClockInit.swift
// already uses (that file's own `rccBase`/`rccApb1Enr1` are file-private,
// so redeclared here). AHB2ENR (GPIOA clock gate) lives at offset 0x4C,
// confirmed via stm32wb55xx.h's RCC_TypeDef (`AHB2ENR`, "Address offset:
// 0x4C"); APB1ENR1 (USB peripheral clock gate) at offset 0x58, matching
// ClockInit.swift's own CRSEN use of the same register.
private let rccBase: UInt32 = 0x5800_0000
private let rccAhb2Enr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x4C))!
private let rccApb1Enr1 = UnsafeMutablePointer<UInt32>(bitPattern: UInt(rccBase + 0x58))!
private let rccAhb2EnrGpioaEn: UInt32 = 1 << 0 // RCC_AHB2ENR_GPIOAEN_Pos, confirmed in stm32wb55xx.h
private let rccApb1Enr1UsbEn: UInt32 = 1 << 26 // RCC_APB1ENR1_USBEN_Pos, confirmed in stm32wb55xx.h

private let afAlternateFunctionMode: UInt32 = 0b10
private let af10: UInt32 = 0b1010 // GPIO_AF10_USB, confirmed against ST's own P-NUCLEO-WB55.Nucleo HID_Standalone example (usbd_conf.c's HAL_PCD_MspInit)

// Unlike F4's dwc2_clock_init() (a documented no-op requiring the
// application to enable OTG_FS's own peripheral clock/pins itself),
// dcd_stm32_fsdev.c's own header comment says the same thing explicitly for
// fsdev: "Enable USB clock; Perhaps use __HAL_RCC_USB_CLK_ENABLE()" and
// "Remap pins to be D+/D- ... needs to go through ... register" — this
// driver does not touch RCC or GPIO itself (verified: no RCC_/GPIO_ writes
// anywhere in dcd_stm32_fsdev.c or fsdev_common.c). ST's own HAL reference
// for this exact board (P-NUCLEO-WB55.Nucleo's USB_Device/HID_Standalone
// example, usbd_conf.c's HAL_PCD_MspInit) confirms both steps are required
// on WB55 unlike some fsdev MCUs with dedicated USB pins: PA11/PA12 must be
// muxed to AF10 (USB_DM/USB_DP are NOT dedicated pins on this chip), and
// RCC_APB1ENR1_USBEN must be set before the driver runs. HSI48+CRS (the
// USB 48MHz clock) are already brought up unconditionally by
// ports/stm32wb/ClockInit.swift's smk_clock_init(), called before
// app_main_swift() — not redone here.
private func enableUsbClockAndPins() {
    rccAhb2Enr.pointee |= rccAhb2EnrGpioaEn
    rccApb1Enr1.pointee |= rccApb1Enr1UsbEn

    // PA11 = USB_DM, PA12 = USB_DP, both alternate-function mode, AF10.
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

// fsdev interrupt forwarding: unlike F4's dwc2 (a single OTG_FS_IRQHandler
// vector), WB55's fsdev driver enables TWO NVIC vectors —
// confirmed via the vendored TinyUSB source (fsdev_stm32.h's fsdev_irq[]
// table, `#elif CFG_TUSB_MCU == OPT_MCU_STM32WB: USB_HP_IRQn, USB_LP_IRQn`)
// and cross-checked against cmsis-device-wb's own startup assembly
// (startup_stm32wb55xx_cm4.s's vector table: `USB_HP_IRQHandler`,
// `USB_LP_IRQHandler`, both weak-aliased to Default_Handler by default).
// dcd_int_enable() (called internally during tusb_rhport_init below, via
// dcd_init()) unconditionally NVIC_EnableIRQ's both — without both vectors
// forwarding here, either would fall through to Default_Handler's infinite
// loop the first time it fires, same class of bug F4's own OTG_FS_IRQHandler
// comment documents. `tusb_int_handler` is TinyUSB's real exported ISR body
// (src/tusb.c), verified directly against the vendored source to call
// through to dcd_int_handler (this driver's own ISR entry point).
@_extern(c, "tusb_int_handler")
func tusb_int_handler(_ rhport: UInt8, _ inIsr: Bool)

@_cdecl("USB_HP_IRQHandler")
func USB_HP_IRQHandler() {
    tusb_int_handler(0, true)
}

@_cdecl("USB_LP_IRQHandler")
func USB_LP_IRQHandler() {
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
// requirement ports/stm32f4/UsbHid.swift's tusb_time_millis_api already
// documents (verified against the vendored tusb.c). Uncalibrated per-call
// counter, NOT a real millisecond clock — no hardware timer wired up yet.
private var s_millisCounter: UInt32 = 0

@_cdecl("tusb_time_millis_api")
func tusb_time_millis_api() -> UInt32 {
    s_millisCounter &+= 1
    return s_millisCounter
}

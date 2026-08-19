// SAMD21 USB HID glue via TinyUSB's dcd_samd driver. The "wired" half of
// the SMK contract — the XIAO M0 has no radio, so this board is USB-only.
// Mirrors ports/stm32f4/UsbHid.swift; only the clock/pin enable differs.
//
// Register facts verified against the vendored DFP (samd21g18a.h,
// component/{pm,gclk,port}.h) and TinyUSB's own samd2x_l2x family.c:
//   PM 0x4000_0400: AHBMASK 0x14 (USB bit 6), APBBMASK 0x1C (USB bit 5)
//   GCLK CLKCTRL (16-bit @ 0x4000_0C02): ID_USB = 0x6, GEN0 in [11:8],
//     CLKEN bit 14 — feeds the USB peripheral from the 48MHz GCLK0
//   PORT group A: PA24/PA25 are USB DM/DP on peripheral function G (PMUX
//     value 6); PMUX regs are one byte per pin pair at 0x30 (pair 12 for
//     pins 24/25, even pin low nibble), PINCFG at 0x40 + pin (PMUXEN bit 0)
// USB pad calibration (PADCAL from the factory fuses) is done by TinyUSB's
// dcd_samd.c itself — verified against the vendored source, no glue needed.

private let pmAhbMask = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0x4000_0400 + 0x14))!
private let pmApbBMask = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0x4000_0400 + 0x1C))!
private let pmAhbMaskUsb: UInt32 = 1 << 6
private let pmApbBMaskUsb: UInt32 = 1 << 5

private let gclkClkCtrl16 = UnsafeMutablePointer<UInt16>(bitPattern: UInt(0x4000_0C02))!
private let clkCtrlIdUsb: UInt16 = 0x6
private let clkCtrlGen0: UInt16 = 0 << 8
private let clkCtrlClkEn: UInt16 = 1 << 14

private let portABase2: UInt32 = 0x4100_4400
private let portAPmux12 = UnsafeMutablePointer<UInt8>(bitPattern: UInt(portABase2 + 0x30 + 12))! // pins 24/25
private let portAPinCfg24 = UnsafeMutablePointer<UInt8>(bitPattern: UInt(portABase2 + 0x40 + 24))!
private let portAPinCfg25 = UnsafeMutablePointer<UInt8>(bitPattern: UInt(portABase2 + 0x40 + 25))!
private let pinCfgPmuxEn: UInt8 = 1 << 0
private let pmuxFunctionG: UInt8 = 6

// TEMPORARY bring-up trap (platform_glue.c): repeating groups of `code`
// blinks, forever.
@_extern(c, "dbg_trap")
func dbg_trap(_ code: Int32)

private func enableUsbClockAndPins() {
    pmAhbMask.pointee |= pmAhbMaskUsb
    pmApbBMask.pointee |= pmApbBMaskUsb
    gclkClkCtrl16.pointee = clkCtrlIdUsb | clkCtrlGen0 | clkCtrlClkEn

    // TEMPORARY: read back the USB GCLK channel (select the channel by
    // writing its ID to CLKCTRL's low byte, then read the 16-bit register)
    // and trap with repeating 4-blink groups if CLKEN didn't stick.
    let clkCtrl8 = UnsafeMutablePointer<UInt8>(bitPattern: UInt(0x4000_0C02))!
    clkCtrl8.pointee = UInt8(clkCtrlIdUsb)
    if (gclkClkCtrl16.pointee & clkCtrlClkEn) == 0 {
        dbg_trap(4)
    }

    // PA24 = DM, PA25 = DP, both muxed to function G (USB).
    portAPmux12.pointee = pmuxFunctionG | (pmuxFunctionG << 4)
    portAPinCfg24.pointee = pinCfgPmuxEn
    portAPinCfg25.pointee = pinCfgPmuxEn
}

@_extern(c, "tusb_rhport_init")
func tusb_rhport_init(_ rhport: UInt8, _ rhInit: UnsafeRawPointer?) -> Bool

@_extern(c, "tud_task_ext")
func tud_task_ext(_ timeoutMs: UInt32, _ inIsr: Bool)

@_extern(c, "tud_hid_n_ready")
func tud_hid_n_ready(_ instance: UInt8) -> Bool

@_extern(c, "tud_hid_n_keyboard_report")
func tud_hid_n_keyboard_report(_ instance: UInt8, _ reportID: UInt8, _ modifier: UInt8, _ keycode: UnsafePointer<UInt8>) -> Bool

// Implemented in ports/common/usb_descriptors.c.
@_extern(c, "smk_keymap_usb_service")
func smk_keymap_usb_service()

// USB interrupt forwarding — startup_samd21.c's vector table weak-aliases
// USB_Handler to an infinite-loop Dummy_Handler, and dcd_samd's dcd_init
// enables the USB NVIC line, so without this override the first USB event
// hangs the firmware. Same class of fix as ports/stm32f4/UsbHid.swift's
// OTG_FS_IRQHandler.
@_extern(c, "tusb_int_handler")
func tusb_int_handler(_ rhport: UInt8, _ inIsr: Bool)

// TEMPORARY: log every ISR entry's INTFLAG/EPINTFLAG bytes over UART,
// read BEFORE tusb_int_handler processes (and clears) them — this
// replaces the earlier LED-blink accumulator, which produced a flag
// combination (SUSPEND+MSOF, no EORST) that didn't logically add up and
// couldn't be trusted from eyeballed multi-bit blink counts alone.
// DEVICE.INTFLAG (global) is at USB base 0x41005000 + 0x01C: bit0=SUSPEND,
// bit2=SOF, bit3=EORST, bit4=WAKEUP. DEVICE.DeviceEndpoint[0].EPINTFLAG is
// at +0x107: bit0=TRCPT0, bit1=TRCPT1, bit4=RXSTP (a SETUP packet actually
// reached EP0 — the key signal for "did enumeration even start"). Capped
// at 20 logged entries so a genuine storm doesn't flood the UART forever.
private let usbIntFlag = UnsafeMutablePointer<UInt8>(bitPattern: UInt(0x4100_501C))!
private let usbEp0IntFlag = UnsafeMutablePointer<UInt8>(bitPattern: UInt(0x4100_5107))!
private var usbIsrHitCount: UInt32 = 0

@_cdecl("USB_Handler")
func USB_Handler() {
    usbIsrHitCount &+= 1
    let intFlags = usbIntFlag.pointee
    let ep0Flags = usbEp0IntFlag.pointee
    if usbIsrHitCount <= 20 {
        uartDebugWriteHex("USB IRQ #\(usbIsrHitCount) INTFLAG", UInt32(intFlags))
        uartDebugWriteHex("         EP0 INTFLAG", UInt32(ep0Flags))
    }
    tusb_int_handler(0, true)
}

// TEMPORARY: direct dcd probe — dcd_samd's dcd_init ignores rh_init and
// returns true; if it HANGS, the USB peripheral clock never arrived.
@_extern(c, "dcd_init")
func dcd_init(_ rhport: UInt8, _ rhInit: UnsafeRawPointer?) -> Bool

@_extern(c, "dbg_blink")
func dbg_blink(_ times: Int32)

func init_wired_link() {
    enableUsbClockAndPins()
    uartDebugWrite("init_wired_link: clock+pins configured, calling tusb_rhport_init\n")
    if !tusb_rhport_init(0, nil) {
        uartDebugWrite("init_wired_link: tusb_rhport_init FAILED\n")
        dbg_trap(8)              // TEMPORARY: repeating 8-groups = usbd-layer failure
    }
    uartDebugWrite("init_wired_link: tusb_rhport_init OK\n")
    dbg_blink(7)                 // TEMPORARY: full USB init reported success
}

// Pump TinyUSB. Called every scan tick from platform_glue.c's vTaskDelay —
// a real Swift/C boundary crossing, hence @_cdecl.
@_cdecl("kb_usb_task")
func kb_usb_task() {
    tud_task_ext(UInt32.max, false)
    smk_keymap_usb_service()
}

// Send a standard 8-byte boot-keyboard report: [modifier][reserved][6 keys].
func send_wired_report(_ modifier: UInt8, _ keys: UnsafePointer<UInt8>) {
    guard tud_hid_n_ready(0) else { return }
    _ = tud_hid_n_keyboard_report(0, 0, modifier, keys)
}

// TEMPORARY bring-up probe: exercises the Swift heap (array allocation)
// and String→C-string conversion — the exact machinery the first kb_log()
// call in app_main_swift needs — in isolation, between LED markers in
// platform_glue.c's main(). Remove once USB enumeration works.
@_cdecl("smk_debug_probe")
func smk_debug_probe() -> Int32 {
    var arr = [UInt8](repeating: 0, count: 64)
    arr[1] = 42
    var total: Int32 = 0
    "probe".utf8CString.withUnsafeBufferPointer { p in total = Int32(p.count) }
    return total + Int32(arr[1])
}

// TinyUSB requires this under CFG_TUSB_OS == OPT_OS_NONE — uncalibrated
// per-call counter, NOT a real millisecond clock (same status as the
// stm32f4/nrf52840 ports; a real SysTick-based clock is future work).
private var s_millisCounter: UInt32 = 0

@_cdecl("tusb_time_millis_api")
func tusb_time_millis_api() -> UInt32 {
    s_millisCounter &+= 1
    return s_millisCounter
}

// RP2040 USB HID glue — Swift port of the former
// ports/rp2040/platform/usb_hid.c. Same tud_* macro/inline gotcha
// ports/nrf52840/UsbHid.swift already solved: tusb_init()/tud_task()/
// tud_hid_ready()/tud_hid_keyboard_report() are macros or static inline
// wrappers with no real linkable symbol; bind to the real underlying
// entry points instead (verified against pico-sdk's bundled TinyUSB at
// ~/pico-sdk/lib/tinyusb — a separate checkout from the nRF52840 port's
// standalone ~/tinyusb, but this build happens to vendor the same
// tinyusb_rhport_init/tud_task_ext/tud_hid_n_ready/tud_hid_n_keyboard_report
// signatures, confirmed by reading src/tusb.c, src/device/usbd.h, and
// src/class/hid/hid_device.h under ~/pico-sdk/lib/tinyusb directly).
//
//   init_wired_link()              -> bring up the TinyUSB device stack
//   send_wired_report(mod, keys)   -> send a boot-keyboard report
//   kb_usb_task()                  -> pump TinyUSB (called from the delay shim)

@_extern(c, "tusb_rhport_init")
func tusb_rhport_init(_ rhport: UInt8, _ rhInit: UnsafeRawPointer?) -> Bool

@_extern(c, "tud_task_ext")
func tud_task_ext(_ timeoutMs: UInt32, _ inIsr: Bool)

@_extern(c, "tud_hid_n_ready")
func tud_hid_n_ready(_ instance: UInt8) -> Bool

@_extern(c, "tud_hid_n_keyboard_report")
func tud_hid_n_keyboard_report(_ instance: UInt8, _ reportID: UInt8, _ modifier: UInt8, _ keycode: UnsafePointer<UInt8>) -> Bool

// Implemented in platform/usb_descriptors.c (a C function) — this crosses
// the Swift/C boundary, so (unlike a same-module Swift-to-Swift call) needs
// @_extern(c, ...), matching this file's own tud_* declarations.
@_extern(c, "smk_keymap_usb_service")
func smk_keymap_usb_service()

func init_wired_link() {
    // rhport 0, nil rh_init: same "backward compatible tusb_init(void)" path
    // the tusb_init() macro takes, defaulting to device role/full-speed per
    // CFG_TUSB_RHPORT0_MODE (tusb_config.h).
    _ = tusb_rhport_init(0, nil)
}

// @_cdecl, not a plain function: at the point this task lands,
// ports/rp2040/platform/platform_glue.c is still C and calls this directly
// via its own `extern void kb_usb_task(void);` — a real Swift/C boundary
// crossing. Once Task 3 ports platform_glue.c's vTaskDelay to Swift, this
// becomes reachable as a same-module call too, but the @_cdecl attribute is
// harmless to leave in place (it just also exposes the C-linkage symbol,
// unused from C at that point) — Task 3 does not need to (and should not)
// remove it here.
@_cdecl("kb_usb_task")
func kb_usb_task() {
    tud_task_ext(UInt32.max, false) // wait-forever, not-in-ISR: same as tud_task()
    smk_keymap_usb_service()
}

// Send a standard 8-byte boot-keyboard report: [modifier][reserved][6 keys].
// `keys` points to the 6 active keycodes (matches HIDReport.keys in Main.swift).
func send_wired_report(_ modifier: UInt8, _ keys: UnsafePointer<UInt8>) {
    guard tud_hid_n_ready(0) else { return }
    _ = tud_hid_n_keyboard_report(0, 0, modifier, keys)
}

// nRF52840 USB HID glue — Swift port of ports/rp2040/platform/usb_hid.c's
// three functions (@_extern(c, ...) calls into TinyUSB's tud_* API, same
// shape Sources/smk/GPIOInit.swift already uses for ESP-IDF's driver
// functions). The "wired" half of the SMK contract.
//
// NOTE on symbol choice: this task's brief called for declaring
// tusb_init/tud_task/tud_hid_ready/tud_hid_keyboard_report directly, mirroring
// the *names* used in ports/rp2040/platform/usb_hid.c. That works fine in a
// C file (it's just calling into headers), but doesn't work from Swift: in
// the vendored ~/tinyusb checkout, `tusb_init` is a variadic **macro**
// (tusb.h) and `tud_task`/`tud_hid_ready`/`tud_hid_keyboard_report` are all
// `static inline` C functions (device/usbd.h, class/hid/hid_device.h) — none
// of those has a real, externally-linkable symbol for `@_extern(c, ...)` to
// bind to; a Swift build declaring them that way fails at link time with
// undefined references. Each has been swapped 1:1 for the real exported
// function it forwards to (verified in the vendored source):
//   tusb_init()                                -> tusb_rhport_init(0, nil)
//   tud_task()                                  -> tud_task_ext(.max, false)
//   tud_hid_ready()                             -> tud_hid_n_ready(0)
//   tud_hid_keyboard_report(id, mod, keycodes)  -> tud_hid_n_keyboard_report(0, id, mod, keycodes)
// Behavior is unchanged — these are exactly what the inline/macro forms
// expand to for a single-port, single-HID-instance-0 device (this board's
// setup, per tusb_config.h's CFG_TUSB_RHPORT0_MODE / CFG_TUD_HID).

@_extern(c, "tusb_rhport_init")
func tusb_rhport_init(_ rhport: UInt8, _ rhInit: UnsafeRawPointer?) -> Bool

@_extern(c, "tud_task_ext")
func tud_task_ext(_ timeoutMs: UInt32, _ inIsr: Bool)

@_extern(c, "tud_hid_n_ready")
func tud_hid_n_ready(_ instance: UInt8) -> Bool

@_extern(c, "tud_hid_n_keyboard_report")
func tud_hid_n_keyboard_report(_ instance: UInt8, _ reportID: UInt8, _ modifier: UInt8, _ keycode: UnsafePointer<UInt8>) -> Bool

// Implemented in platform/usb_descriptors.c (a C function) — this crosses
// the Swift/C boundary, so (unlike a same-module Swift-to-Swift call)
// needs @_extern(c, ...), matching this file's own tud_* declarations.
@_extern(c, "smk_keymap_usb_service")
func smk_keymap_usb_service()

func init_wired_link() {
    // rhport 0, nil rh_init: same "backward compatible tusb_init(void)" path
    // the tusb_init() macro takes, defaulting to device role/full-speed per
    // CFG_TUSB_RHPORT0_MODE (tusb_config.h).
    _ = tusb_rhport_init(0, nil)
}

// Pump TinyUSB. Must be called frequently from the main loop; the
// vTaskDelay shim in platform_glue.c (a C file) calls this every scan
// tick via its own `extern void kb_usb_task(void);` declaration — that
// crosses the Swift/C boundary for real (unlike init_wired_link/
// send_wired_report below, called only from Main.swift, plain Swift-to-
// Swift same-module resolution), so this one needs @_cdecl.
@_cdecl("kb_usb_task")
func kb_usb_task() {
    tud_task_ext(UInt32.max, false) // wait-forever, not-in-ISR: same as tud_task()
    smk_keymap_usb_service()
}

// Send a standard 8-byte boot-keyboard report: [modifier][reserved][6 keys].
func send_wired_report(_ modifier: UInt8, _ keys: UnsafePointer<UInt8>) {
    guard tud_hid_n_ready(0) else { return }
    _ = tud_hid_n_keyboard_report(0, 0, modifier, keys)
}

// TinyUSB's own weak default for this symbol (src/tusb.c) only exists when
// CFG_TUSB_OS != OPT_OS_NONE; tusb_config.h sets OPT_OS_NONE here (no RTOS),
// so — per tusb.c's own comment ("tusb_time_millis_api() must be implemented
// by user application") — TinyUSB requires the app to supply it, or the
// link fails outright with an undefined reference (discovered empirically:
// tusb_time_delay_ms_api's OPT_OS_NONE fallback body, compiled unconditionally
// into tusb.c, references it). Crosses the Swift/C boundary for real (called
// from TinyUSB's C sources), hence @_cdecl.
//
// Like vTaskDelay's busy-loop in platform_glue.c, this is an UNCALIBRATED
// per-call counter, NOT a real millisecond clock — no hardware timer is
// wired up yet (Task 5's MPSL/RTC init claims that peripheral). It's only
// enough to guarantee any bounded `while (tusb_time_millis_api() - t0 < ms)`
// wait TinyUSB does internally terminates, not that it takes the right
// amount of real time; needs a real tick source before hardware bring-up.
private var s_millisCounter: UInt32 = 0

@_cdecl("tusb_time_millis_api")
func tusb_time_millis_api() -> UInt32 {
    s_millisCounter &+= 1
    return s_millisCounter
}

// RP2040 board/connection-mode config and logging — Swift port of the
// portable half of ports/rp2040/platform/platform_glue.c. main(),
// posix_memalign, and the Unicode-stdlib linker stubs stay in
// platform_glue.c — see that file's own comments and this plan's design
// spec for why (real C-runtime entry point / Swift-runtime bootstrap
// shims with genuine bootstrapping-order risk if moved).

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@_extern(c, "printf")
func printf(_ format: UnsafePointer<CChar>, _ arg: UnsafePointer<CChar>) -> Int32

func kb_log(_ msg: UnsafePointer<CChar>) {
    _ = printf("[SMK] %s\n", msg)
}

// RP2040 always has real native-USB wired HID (UsbHid.swift/TinyUSB), so
// it's always available and stays the boot default, unchanged from before
// this option existed.
func smk_has_wired_bridge() -> Int32 { 1 }
func smk_default_mode_is_wired() -> Int32 { 1 }

// No @_extern for kb_usb_task: Task 2 already ported it to Swift
// (ports/rp2040/UsbHid.swift, @_cdecl("kb_usb_task") — kept @_cdecl there
// for a reason specific to when Task 2 landed, but that doesn't stop this
// same-module call from working). Declaring @_extern(c, "kb_usb_task")
// here as well would be a same-module redeclaration conflict, not a
// harmless duplicate — see this project's established SourceKit lesson
// on exactly this mistake (feedback/CLAUDE.md history: same-module
// Swift-to-Swift calls need neither @_extern nor @_cdecl).

#if SMK_BOARD_KBD_RP2040
@_extern(c, "ble_kbd_uart_poll")
func ble_kbd_uart_poll()
#endif

@_extern(c, "sleep_ms")
func sleep_ms(_ ms: UInt32)

@_cdecl("vTaskDelay")
func vTaskDelay(_ ticks: UInt32) {
    kb_usb_task()
    #if SMK_BOARD_KBD_RP2040
    ble_kbd_uart_poll()
    #endif
    sleep_ms(ticks == 0 ? 1 : ticks)
}

// BLE HID glue for Pico W — Swift port of the former
// ports/rp2040/platform/ble_hid.c's SMK_ENABLE_BLE branch. The transport
// here is pico-sdk's cyw43_arch, which owns BTstack's transport setup and
// run loop internally — no hci_transport_t-equivalent exists in this file
// at all. The HID-over-GATT half that used to live here is now the shared
// ports/common/BleHidGatt.swift (compiled in alongside this file for
// pico_w/pico2_w — see ports/rp2040/CMakeLists.txt), where its full
// constant/layout verification notes moved too.
//
// Compiled for every non-smk_kbd_rp2040 RP2040 board (plain Pico, Pico W,
// Pico 2, Pico 2 W) — always included in ports/rp2040/CMakeLists.txt's
// Swift source list, exactly like the deleted ble_hid.c was always
// included in the C source list for those boards. The real-vs-stub split
// below (#if SMK_ENABLE_BLE) mirrors that file's own #ifdef SMK_ENABLE_BLE
// / #else, driven by the same -DSMK_ENABLE_BLE define (set only for
// pico_w/pico2_w), passed to swiftc as a bare -D so this file's #if sees
// it (see ports/rp2040/CMakeLists.txt's _smk_swift_defs). BleHidGatt.swift
// is only in the source list when SMK_ENABLE_BLE is set, so the #else
// branch must supply both stubs itself.

#if SMK_ENABLE_BLE

@_extern(c, "cyw43_arch_init")
func cyw43_arch_init() -> Int32

func init_ble_hid() {
    guard cyw43_arch_init() == 0 else { return } // wireless init failed; USB path still works
    // cyw43_arch has installed BTstack's run loop and HCI transport by this
    // point; the shared GATT setup finishes the job (and powers HCI on).
    smk_ble_hid_gatt_setup()
}

#else // !SMK_ENABLE_BLE — plain Pico / Pico 2 (no CYW43 radio): no-op
      // stubs, matching the deleted ble_hid.c's own #else branch so the
      // shared scan loop (Main.swift) links and runs USB-only.

func init_ble_hid() {}

func send_keyboard_report(_ modifier: UInt8, _ keys: UnsafePointer<UInt8>) {
    _ = modifier
    _ = keys
}

#endif // SMK_ENABLE_BLE

// BLE HID glue for smk_kbd_rp2040 — Swift port of the former
// ports/rp2040/platform/ble_hid_kbd_uart.c. Talks to the CYW43439 over
// this board's dedicated 4-wire Bluetooth UART (GPIO20/21 + CTS/RTS on
// 22/23, BT_REG_ON on GPIO18, BT_DEV_WAKE on GPIO19, BT_HOST_WAKE on
// GPIO28 — see generate_kbd_rp2040.py's GPIO map) instead of Pico W's
// onboard CYW43 SPI/PIO link. Only compiled in for
// SMK_TARGET_BOARD=smk_kbd_rp2040 (see ports/rp2040/CMakeLists.txt);
// BleHidPicoW.swift is excluded from the build in that case, so there's
// exactly one definition of init_ble_hid()/send_keyboard_report() per
// target.
//
// btstack_uart_block_t's struct literal stays in uart_driver_vtable.c
// (Global Constraints: vtable structs stay C, callback bodies don't have
// to) — every uart_driver_* function below is Swift, referenced by that
// C file's struct initializer by symbol name. See that file's own header
// comment for the four distinct reasons C code still exists at all here
// (vtable struct, async_context_poll_t's genuine complexity, the `uart1`
// macro-not-a-symbol problem, and four static-inline pico-sdk UART calls
// with no linkable symbol).
//
// *** STATUS as of this port: power/UART transport, BTstack
// chipset/patchram wiring, and the cooperative run-loop pump are all real
// and datasheet-verified (preserved from the deleted C file below, on
// cyw43439PowerUp/cyw43439BtInit). cyw43439_patchram.c now carries real,
// correctly-sized PatchRAM firmware data (brcm_patch_ram_length = 6979,
// sourced from Murata's public cyw-bt-patch repo per this board's
// CYW43439→"1YN" module mapping — see that file's own header), so the chip
// is no longer stuck on its ROM-only HCI command set. What remains
// unverified is real hardware confirmation that this is the *correct*
// patch revision for the specific chip on this board (matched by part
// number, not yet confirmed via a live `lmp_subversion` read — see
// CLAUDE.md's smk_kbd_rp2040 row), not whether firmware data exists at
// all. ***
//
// Verified against the CYW43439 datasheet (Cypress/Infineon doc 002-30348
// Rev *D, in ~/esp/SMK_Keyboard/datasheets/cyw43439_lcsc.pdf) while writing
// the deleted C file this replaces:
//   - Section 8 "Microprocessor and Memory Unit for Bluetooth": Bluetooth
//     has its own ARM Cortex-M3 core, 576KB ROM + 160KB RAM/patch memory,
//     and its own POR gated by BT_REG_ON alone — confirms this board's
//     BT-only-over-UART approach (WLAN held in reset, no SPI/gSPI wiring
//     at all) is a real, independent configuration, not a workaround.
//   - Section 19.1.1 / Figure 35 "WLAN = OFF, Bluetooth = ON": this exact
//     configuration is a documented reference case.
//   - Section 9.2 "UART Interface": default baud 115.2 kbaud, H4 transport
//     supported — matches btUartBaudBoot below and hci_transport_h4
//     already in use.
// This resolved an earlier (wrong) concern that Pico W's SPI-based BT
// transport (cyw43-driver's combined WiFi+BT memory-image loader) meant
// this chip needed the WLAN backplane for BT bring-up — it doesn't; Pico
// W's SPI routing is a Raspberry Pi board design choice, not a chip
// requirement.
//
// PatchRAM integration uses BTstack's own btstack_chipset_bcm driver (the
// same one used for e.g. Raspberry Pi 3/4/Zero W's BCM4345-family UART
// BT). There's no setter function to call: btstack_chipset_bcm.c's
// embedded (non-POSIX) build reads the firmware image straight from three
// extern globals (brcm_patchram_buf/brcm_patch_ram_length/
// brcm_patch_version, defined in cyw43439_patchram.c) once
// hci_set_chipset() below points it at btstack_chipset_bcm_instance() —
// BTstack's hci.c runs the whole Download-Minidriver/Write-RAM/Launch-RAM
// sequence internally from there; nothing bespoke needed here.
//
// send_keyboard_report() degrades gracefully either way (no-ops without a
// connection), so USB HID keeps working regardless of BLE's state.
//
// The HID-over-GATT half below (from `l2cap_init()` down through
// `send_keyboard_report`) is copied directly from
// ports/rp2040/BleHidPicoW.swift (Task 12), not re-derived — see that
// file for the shared shape/reasoning, including the permanent-copy fix
// for two BTstack-retained buffers (hidDescriptorKeyboardBytes/
// advDataBytes) that file's own review round landed on. Only the
// transport bring-up above it (this board's dedicated UART link to a
// CYW43439, vs. Pico W's onboard cyw43_arch) differs.
//
// Every numeric constant/type below was cross-checked against the real
// vendored pico-sdk (~/pico-sdk) during this port. Two placeholders in
// this task's own plan turned out wrong against the real headers:
//   - UART_PARITY_EVEN is 1, not 2 (hardware/uart.h's uart_parity_t enum
//     is NONE=0, EVEN=1, ODD=2 — the plan's `parity ? 2 : 0` would have
//     silently configured ODD parity instead of EVEN).
//   - gpio_set_function's `fn` parameter and uart_set_format's `parity`
//     parameter are both C enums with <=255 values, so this project's
//     -fshort-enums RP2040 build (ports/rp2040/CMakeLists.txt) sizes them
//     to 1 byte, matching arm-none-eabi-gcc's real codegen — UInt8, not
//     the plan's Int32 (same established pattern as BleHidPicoW.swift's
//     io_capability_t handling).
// Also: several APIs the plan assumed were plain externs
// (uart_write_blocking, uart_is_readable, uart_getc, uart_set_hw_flow)
// are actually `static inline` in hardware/uart.h with no linkable
// symbol — routed through uart_driver_vtable.c's smk_uart_* wrappers
// instead, matching gpio_init_wrappers.c's already-established pattern
// for the same class of problem. gpio_init/smk_gpio_set_dir/smk_gpio_put/
// smk_gpio_pull_down/sleep_ms are NOT re-declared here — they're already
// `@_extern(c, ...)` in GPIOInit.swift/PlatformConfig.swift, both always
// compiled into this same module; redeclaring them here would be a
// same-module redeclaration conflict (established SourceKit lesson, see
// PlatformConfig.swift's own comment on kb_usb_task).

// --- Board pin map (generate_kbd_rp2040.py) --------------------------------
private let pinBtUartTx: UInt32 = 20
private let pinBtUartRx: UInt32 = 21
private let pinBtUartCts: UInt32 = 22
private let pinBtUartRts: UInt32 = 23
private let pinBtRegOn: UInt32 = 18
private let pinBtDevWake: UInt32 = 19
private let pinBtHostWake: UInt32 = 28
private let btUartBaudBoot: UInt32 = 115200 // CYW43439 default HCI UART baud out of reset

// --- pico-sdk UART/GPIO externs ---------------------------------------------

@_extern(c, "uart_init")
func uart_init(_ uartInst: UnsafeMutableRawPointer?, _ baudrate: UInt32) -> UInt32

// gpio_function_t (io_bank0.h's gpio_function_rp2040 enum) tops out at
// GPIO_FUNC_NULL=0x1f — fits in 1 byte under -fshort-enums. UInt8, not Int32.
@_extern(c, "gpio_set_function")
func gpio_set_function(_ gpioNum: UInt32, _ fn: UInt8)

// uart_set_hw_flow is `static inline` in hardware/uart.h (verified) — no
// linkable symbol; routed through uart_driver_vtable.c's wrapper instead.
@_extern(c, "smk_uart_set_hw_flow")
func smk_uart_set_hw_flow(_ uartInst: UnsafeMutableRawPointer?, _ cts: Bool, _ rts: Bool)

// uart_parity_t (hardware/uart.h) has 3 enumerators (NONE=0, EVEN=1,
// ODD=2) — fits in 1 byte under -fshort-enums. UInt8, not Int32.
@_extern(c, "uart_set_format")
func uart_set_format(_ uartInst: UnsafeMutableRawPointer?, _ dataBits: UInt32, _ stopBits: UInt32, _ parity: UInt8)

@_extern(c, "uart_set_fifo_enabled")
func uart_set_fifo_enabled(_ uartInst: UnsafeMutableRawPointer?, _ enabled: Bool)

@_extern(c, "uart_set_baudrate")
func uart_set_baudrate(_ uartInst: UnsafeMutableRawPointer?, _ baudrate: UInt32) -> UInt32

// uart_write_blocking / uart_is_readable / uart_getc are all `static
// inline` in hardware/uart.h (verified) — no linkable symbol; routed
// through uart_driver_vtable.c's smk_uart_* wrappers instead.
@_extern(c, "smk_uart_write_blocking")
func smk_uart_write_blocking(_ uartInst: UnsafeMutableRawPointer?, _ src: UnsafePointer<UInt8>, _ len: Int)

@_extern(c, "smk_uart_is_readable")
func smk_uart_is_readable(_ uartInst: UnsafeMutableRawPointer?) -> Bool

@_extern(c, "smk_uart_getc")
func smk_uart_getc(_ uartInst: UnsafeMutableRawPointer?) -> UInt8

// pico-sdk's `uart1` is a `#define uart1 ((uart_inst_t *)uart1_hw)` macro,
// not a real linkable global (verified against hardware/uart.h) — there is
// no C symbol named `uart1` for a Swift `@_extern(c, "uart1")` to bind to
// at all, so this one-line C accessor (uart_driver_vtable.c) is the only
// option, not a judgment call between alternatives.
@_extern(c, "bt_uart_instance")
func bt_uart_instance() -> UnsafeMutableRawPointer?

@_extern(c, "smk_async_context_setup")
func smk_async_context_setup() -> UnsafeMutableRawPointer?

@_extern(c, "smk_async_context_poll")
func smk_async_context_poll()

@_extern(c, "btstack_run_loop_init")
func btstack_run_loop_init(_ runLoop: UnsafeMutableRawPointer?)

@_extern(c, "hci_init")
func hci_init(_ transport: UnsafeMutableRawPointer?, _ transportConfig: UnsafeRawPointer?)

@_extern(c, "hci_transport_h4_instance")
func hci_transport_h4_instance(_ uartDriver: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_extern(c, "hci_set_chipset")
func hci_set_chipset(_ chipset: UnsafeMutableRawPointer?)

@_extern(c, "btstack_chipset_bcm_instance")
func btstack_chipset_bcm_instance() -> UnsafeMutableRawPointer?

// smk_uart_driver — the `const btstack_uart_block_t` struct literal in
// uart_driver_vtable.c, needed here as the argument to
// hci_transport_h4_instance. Empirically verified (standalone compile +
// disassemble probe, armv6m-none-none-eabi + Embedded + Extern, matching
// this project's toolchain/flags) that declaring the extern as a scalar
// placeholder type and recovering the REAL struct's address via
// `withUnsafePointer(to:)` produces the correct address-of codegen
// (R_ARM_GOT_PREL relocation against the C symbol, loaded once to yield
// the struct's base address) — this is the exact same pattern
// BleHidPicoW.swift's `profile_data` extern already uses successfully in
// this codebase. The alternative of declaring the extern var's TYPE
// directly as a pointer (`var smk_uart_driver: UnsafeMutableRawPointer`)
// and using its VALUE was also probed and found to be wrong: that
// generates a DEREFERENCE of the struct's first bytes (reinterpreting
// `smk_uart_driver.init`'s first few bytes as if they were a pointer
// value), not an address-of — confirmed by comparing disassembly of both
// patterns against a real multi-field struct global. See
// uart_driver_vtable.c for the C-side struct literal.
@_extern(c, "smk_uart_driver")
var smk_uart_driver: UInt8

// --- btstack_uart_block_t callback bodies -----------------------------------
// Polling/blocking implementation (simplest correct thing to reason about
// without hardware in hand) rather than a fully interrupt/DMA-driven one —
// BTstack calls block_received/block_sent callbacks from its own run loop
// iteration, not from an ISR, so ble_kbd_uart_poll() below drives the run
// loop's "poll" hook to check for pending RX bytes rather than using uart
// IRQs. Adequate for a low-throughput HID link; revisit if real hardware
// testing shows dropped events under load.

private var blockReceivedCb: (@convention(c) () -> Void)? = nil
private var blockSentCb: (@convention(c) () -> Void)? = nil
private var rxBuffer: UnsafeMutablePointer<UInt8>? = nil
private var rxLen: UInt16 = 0
private var rxHave: UInt16 = 0

@_cdecl("uart_driver_init")
func uart_driver_init(_ config: UnsafeRawPointer?) -> Int32 {
    let uart = bt_uart_instance()
    _ = uart_init(uart, btUartBaudBoot)
    gpio_set_function(pinBtUartTx, 2) // GPIO_FUNC_UART — verified 2 (io_bank0.h)
    gpio_set_function(pinBtUartRx, 2)
    gpio_set_function(pinBtUartCts, 2)
    gpio_set_function(pinBtUartRts, 2)
    smk_uart_set_hw_flow(uart, true, true) // CTS/RTS, required by the chip's own flow control
    uart_set_format(uart, 8, 1, 0) // UART_PARITY_NONE — verified 0 (hardware/uart.h)
    uart_set_fifo_enabled(uart, true)
    return 0
}

@_cdecl("uart_driver_open")
func uart_driver_open() -> Int32 { 0 }

@_cdecl("uart_driver_close")
func uart_driver_close() -> Int32 { 0 }

@_cdecl("uart_driver_set_block_received")
func uart_driver_set_block_received(_ handler: (@convention(c) () -> Void)?) {
    blockReceivedCb = handler
}

@_cdecl("uart_driver_set_block_sent")
func uart_driver_set_block_sent(_ handler: (@convention(c) () -> Void)?) {
    blockSentCb = handler
}

@_cdecl("uart_driver_set_baudrate")
func uart_driver_set_baudrate(_ baudrate: UInt32) -> Int32 {
    _ = uart_set_baudrate(bt_uart_instance(), baudrate)
    return 0
}

@_cdecl("uart_driver_set_parity")
func uart_driver_set_parity(_ parity: Int32) -> Int32 {
    // UART_PARITY_NONE=0, UART_PARITY_EVEN=1 (hardware/uart.h's
    // uart_parity_t: NONE, EVEN, ODD) — verified; the plan's placeholder
    // value of 2 for EVEN was WRONG (2 is UART_PARITY_ODD).
    uart_set_format(bt_uart_instance(), 8, 1, parity != 0 ? 1 : 0)
    return 0
}

@_cdecl("uart_driver_set_flowcontrol")
func uart_driver_set_flowcontrol(_ flowcontrol: Int32) -> Int32 {
    smk_uart_set_hw_flow(bt_uart_instance(), flowcontrol != 0, flowcontrol != 0)
    return 0
}

@_cdecl("uart_driver_receive_block")
func uart_driver_receive_block(_ buffer: UnsafeMutablePointer<UInt8>?, _ len: UInt16) {
    rxBuffer = buffer
    rxLen = len
    rxHave = 0
}

@_cdecl("uart_driver_send_block")
func uart_driver_send_block(_ buffer: UnsafePointer<UInt8>?, _ length: UInt16) {
    // The original C always called uart_write_blocking(buffer, length) then
    // fired block_sent_cb unconditionally, regardless of buffer. This path
    // is currently unreachable — BTstack's real hci_transport_h4.c never
    // passes a NULL buffer here — but preserve that exact behavior rather
    // than silently dropping the callback on a hypothetical NULL buffer
    // (the `if let` below only guards the Swift-side pointer dereference
    // needed to call smk_uart_write_blocking; it doesn't gate the callback).
    if let buffer = buffer {
        smk_uart_write_blocking(bt_uart_instance(), buffer, Int(length))
    }
    blockSentCb?()
}

// --- CYW43439 power-up sequencing -------------------------------------------
// Datasheet-verified (Cypress/Infineon doc 002-30348 Rev *D, section 19,
// "Power-Up Sequence and Timing" — see the deleted C file's own header
// comment, preserved here, for the full citations):
//   - BT_REG_ON and WL_REG_ON are internally OR'ed; either alone enables the
//     regulators (section 19.1.1) — we only ever drive BT_REG_ON, matching
//     Figure 35 "WLAN = OFF, Bluetooth = ON".
//   - BT POR releases when BT_REG_ON goes high; max reset duration is 110ms
//     (section 19.1) — the 150ms sleep below is a safe margin above that.
//   - Figure 17 "Startup Signaling Sequence" additionally shows the chip
//     driving BT_UART_RTS_N low only after the host drives BT_UART_CTS_N low
//     AND the chip has finished its own IO/reference-clock settling (its
//     "T3"/"T4" intervals) — hci_transport_h4's hardware flow control
//     (already enabled in uart_driver_init above) handles this handshake at
//     the UART-signal level automatically; no extra software wait is needed
//     beyond giving the chip time to reach that state, which this 150ms
//     already covers with margin.
private func cyw43439PowerUp() {
    gpio_init(pinBtRegOn)
    smk_gpio_set_dir(pinBtRegOn, true)
    smk_gpio_put(pinBtRegOn, false)

    gpio_init(pinBtDevWake)
    smk_gpio_set_dir(pinBtDevWake, true)
    smk_gpio_put(pinBtDevWake, false)

    gpio_init(pinBtHostWake)
    smk_gpio_set_dir(pinBtHostWake, false)
    smk_gpio_pull_down(pinBtHostWake)

    smk_gpio_put(pinBtRegOn, true)
    sleep_ms(150) // let the chip boot its ROM before talking to it
    smk_gpio_put(pinBtDevWake, true)
    sleep_ms(10)
}

// Wires BTstack's generic Broadcom/Cypress/Infineon chipset driver
// (btstack_chipset_bcm — the same one used for Raspberry Pi 3/4/Zero W's
// BCM4345-family UART Bluetooth) into our hci instance. Must be called
// after hci_init() (hci_set_chipset requires an initialized hci core) and
// before hci_power_control(HCI_POWER_ON) (that's what triggers the
// chipset's init()/next_command() sequence — HCI Reset, Read Local
// Version, Download Minidriver, the patchram records, Launch RAM — all
// driven internally by BTstack's hci.c, not by code in this file).
//
// No data actually needs passing here: btstack_chipset_bcm.c's embedded
// build reads brcm_patchram_buf/brcm_patch_ram_length directly (see
// cyw43439_patchram.h) once this points hci at the chipset instance. If
// brcm_patch_ram_length were ever 0, the driver reports
// BTSTACK_CHIPSET_NO_INIT_SCRIPT and skips straight to done, so this stays
// safe to call unconditionally even without real firmware data installed —
// the chip would just stay on its ROM-only command set instead of failing.
private func cyw43439BtInit() {
    hci_set_chipset(btstack_chipset_bcm_instance())
}

// Call regularly from the app's cooperative loop (see vTaskDelay() in
// PlatformConfig.swift). Does two independent jobs each tick:
//  1. Drains the UART RX FIFO into whatever buffer BTstack last requested
//     via receive_block(), firing the block_received callback once full —
//     the "polling" half of this polling H4 transport (see uart_driver_*
//     above; nothing here is IRQ-driven). Drains everything currently
//     available each tick (matching the deleted C file's own `while` loop),
//     not just one byte, so a burst of pairing-procedure bytes doesn't
//     trickle in one poll cycle at a time.
//  2. Pumps BTstack's own run loop (timers, deferred callbacks, and the
//     HCI/L2CAP/SM state machines that those drive) via
//     smk_async_context_poll() — non-blocking, returns immediately if
//     there's nothing to do. Without this call, HCI init would power up
//     and drain UART bytes but never actually process them into state
//     transitions or fire our packet handler.
func ble_kbd_uart_poll() {
    while let buf = rxBuffer, rxHave < rxLen, smk_uart_is_readable(bt_uart_instance()) {
        buf[Int(rxHave)] = smk_uart_getc(bt_uart_instance())
        rxHave += 1
    }
    if rxBuffer != nil, rxHave == rxLen, rxLen > 0 {
        rxBuffer = nil
        rxLen = 0
        rxHave = 0
        blockReceivedCb?()
    }
    smk_async_context_poll()
}

// =============================================================================
// --- HID-over-GATT (copied directly from BleHidPicoW.swift's init_ble_hid/
// send_keyboard_report — see that file for the shared reasoning; only the
// transport bring-up above differs) -------------------------------------------
// =============================================================================

@_extern(c, "l2cap_init")
func l2cap_init()

@_extern(c, "sm_init")
func sm_init()

// sm_set_io_capabilities takes io_capability_t (a C enum) — UInt8 under
// this project's -fshort-enums RP2040 build (verified in BleHidPicoW.swift).
@_extern(c, "sm_set_io_capabilities")
func sm_set_io_capabilities(_ ioCapability: UInt8)

@_extern(c, "sm_set_authentication_requirements")
func sm_set_authentication_requirements(_ authReq: UInt8)

@_extern(c, "att_server_init")
func att_server_init(_ dbData: UnsafePointer<UInt8>?, _ readCallback: UnsafeRawPointer?, _ writeCallback: UnsafeRawPointer?)

@_extern(c, "battery_service_server_init")
func battery_service_server_init(_ battery: UInt8)

@_extern(c, "device_information_service_server_init")
func device_information_service_server_init()

@_extern(c, "hids_device_init")
func hids_device_init(_ hidCountryCode: UInt8, _ descriptor: UnsafePointer<UInt8>, _ descriptorSize: UInt16)

@_extern(c, "gap_advertisements_set_params")
func gap_advertisements_set_params(_ advIntMin: UInt16, _ advIntMax: UInt16, _ advType: UInt8, _ ownAddrType: UInt8, _ directAddr: UnsafePointer<UInt8>, _ channelMap: UInt8, _ filterPolicy: UInt8)

@_extern(c, "gap_advertisements_set_data")
func gap_advertisements_set_data(_ advDataLen: UInt8, _ advData: UnsafeMutablePointer<UInt8>)

@_extern(c, "gap_advertisements_enable")
func gap_advertisements_enable(_ enabled: Int32)

@_extern(c, "hci_add_event_handler")
func hci_add_event_handler(_ registration: UnsafeMutableRawPointer)

@_extern(c, "sm_add_event_handler")
func sm_add_event_handler(_ registration: UnsafeMutableRawPointer)

@_extern(c, "hids_device_register_packet_handler")
func hids_device_register_packet_handler(_ handler: @convention(c) (UInt8, UInt16, UnsafeMutablePointer<UInt8>?, UInt16) -> Void)

@_extern(c, "hci_power_control")
func hci_power_control(_ mode: UInt8) -> Int32

@_extern(c, "hids_device_send_input_report")
func hids_device_send_input_report(_ conHandle: UInt16, _ report: UnsafePointer<UInt8>, _ reportLen: UInt16) -> UInt8

@_extern(c, "hids_device_request_can_send_now_event")
func hids_device_request_can_send_now_event(_ conHandle: UInt16) -> UInt8

// btstack_packet_callback_registration_t — see BleHidPicoW.swift for the
// full verification note on why this mirror struct (not a one-field
// guess) is required.
struct BtstackLinkedItem {
    var next: UnsafeMutableRawPointer?
}

struct BtstackPacketCallbackRegistration {
    var item = BtstackLinkedItem()
    var callback: (@convention(c) (UInt8, UInt16, UnsafeMutablePointer<UInt8>?, UInt16) -> Void)?
}

// profile_data — generated by pico_btstack_make_gatt_header() from
// smk_hid.gatt into the build directory's smk_hid.h. Same GATT profile as
// Pico W's (the HID-over-GATT service doesn't depend on transport); the
// generated symbol is instantiated into a real translation unit by
// platform/smk_hid_gatt_data.c, now compiled in for this board too (see
// CMakeLists.txt — it used to be needed only by the pico_w/pico2_w branch
// because the deleted ble_hid_kbd_uart.c supplied its own
// `#include "smk_hid.h"`).
@_extern(c, "profile_data")
var profile_data: UInt8

// HCI_CON_HANDLE_INVALID (btstack_defines.h) — verified 0xffffu.
private let hciConHandleInvalid: UInt16 = 0xFFFF

// hidDescriptorKeyboard / advData are handed to BTstack calls that store
// the raw pointer LONG-TERM, not just for the duration of the call — see
// BleHidPicoW.swift for the full verification note (hids_device.c:420,
// hci.c's le_advertisements_data). Fixed the same way here: copied into
// permanently allocated, intentionally-never-freed storage once in
// init_ble_hid() below.
private let hidDescriptorKeyboardBytes: [UInt8] = [
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x95, 0x05,
    0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x03,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xc0
]

// Advertisement: flags, appearance (keyboard), 16-bit HID service UUID,
// name. All BLUETOOTH_DATA_TYPE_* type bytes verified against
// bluetooth_data_types.h (see BleHidPicoW.swift).
private let advDataBytes: [UInt8] = [
    0x02, 0x01, 0x06,       // len=2, BLUETOOTH_DATA_TYPE_FLAGS(0x01); General Discoverable + BR/EDR Not Supported
    0x03, 0x19, 0xC1, 0x03, // len=3, BLUETOOTH_DATA_TYPE_APPEARANCE(0x19); 0x03C1 = Keyboard
    0x03, 0x02, 0x12, 0x18, // len=3, BLUETOOTH_DATA_TYPE_INCOMPLETE_LIST_OF_16_BIT_SERVICE_CLASS_UUIDS(0x02); HID service UUID 0x1812
    0x0d, 0x09, 0x53, 0x4D, 0x4B, 0x20, 0x4B, 0x65, 0x79, 0x62, 0x6F, 0x61, 0x72, 0x64, // len=13, BLUETOOTH_DATA_TYPE_COMPLETE_LOCAL_NAME(0x09); "SMK Keyboard"
]

// Permanent copies of the two buffers above — see BleHidPicoW.swift's
// permanentCopy()/hidDescriptorKeyboardStorage comment for the full
// pointer-escape-bug reasoning this carries forward.
private var hidDescriptorKeyboardStorage: UnsafeMutableBufferPointer<UInt8>?
private var advDataStorage: UnsafeMutableBufferPointer<UInt8>?

private func permanentCopy(_ bytes: [UInt8]) -> UnsafeMutableBufferPointer<UInt8> {
    let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
    _ = storage.initialize(from: bytes)
    return storage
}

private var hciEventCallbackRegistration = BtstackPacketCallbackRegistration()
private var smEventCallbackRegistration = BtstackPacketCallbackRegistration()
private let battery: UInt8 = 100
private var conHandle: UInt16 = hciConHandleInvalid
private var protocolMode: UInt8 = 1
private var pendingReport = [UInt8](repeating: 0, count: 8)
private var reportDirty = false

private func sendPending() {
    guard conHandle != hciConHandleInvalid else { return }
    reportDirty = false
    pendingReport.withUnsafeBufferPointer { _ = hids_device_send_input_report(conHandle, $0.baseAddress!, 8) }
}

// hci_event_packet_get_type / hci_event_hids_meta_get_subevent_code /
// hids_subevent_protocol_mode_get_protocol_mode /
// hids_subevent_input_report_enable_get_con_handle are all `static inline`
// in btstack_event.h with no linkable symbol — reimplemented as direct
// byte reads, copied exactly from BleHidPicoW.swift.
private func hciEventPacketGetType(_ event: UnsafePointer<UInt8>) -> UInt8 {
    event[0]
}

private func hciEventHidsMetaGetSubeventCode(_ event: UnsafePointer<UInt8>) -> UInt8 {
    event[2]
}

private func hidsSubeventProtocolModeGetProtocolMode(_ event: UnsafePointer<UInt8>) -> UInt8 {
    event[5]
}

private func hidsSubeventInputReportEnableGetConHandle(_ event: UnsafePointer<UInt8>) -> UInt16 {
    UInt16(event[3]) | (UInt16(event[4]) << 8) // little_endian_read_16(event, 3)
}

@_cdecl("smk_ble_hid_packet_handler")
private func packetHandler(_ packetType: UInt8, _ channel: UInt16, _ packet: UnsafeMutablePointer<UInt8>?, _ size: UInt16) {
    guard packetType == 0x04, let packet = packet else { return } // HCI_EVENT_PACKET
    let eventType = hciEventPacketGetType(packet)
    if eventType == 0x05 { // HCI_EVENT_DISCONNECTION_COMPLETE
        conHandle = hciConHandleInvalid
    } else if eventType == 0xF1 { // HCI_EVENT_HIDS_META
        let subevent = hciEventHidsMetaGetSubeventCode(packet)
        switch subevent {
        case 0x05: // HIDS_SUBEVENT_INPUT_REPORT_ENABLE
            conHandle = hidsSubeventInputReportEnableGetConHandle(packet)
        case 0x02: // HIDS_SUBEVENT_PROTOCOL_MODE
            protocolMode = hidsSubeventProtocolModeGetProtocolMode(packet)
        case 0x01: // HIDS_SUBEVENT_CAN_SEND_NOW
            if reportDirty { sendPending() }
        default:
            break
        }
    }
}

func init_ble_hid() {
    // BTstack's run loop must exist before hci_init(): hci.c registers
    // timers/data-source callbacks against whatever btstack_run_loop_init()
    // configured.
    let runLoop = smk_async_context_setup()
    btstack_run_loop_init(runLoop)

    cyw43439PowerUp()

    let transport = withUnsafePointer(to: &smk_uart_driver) { ptr in
        hci_transport_h4_instance(UnsafeMutableRawPointer(mutating: ptr))
    }
    hci_init(transport, nil)
    cyw43439BtInit() // wires btstack_chipset_bcm; see its comment above

    l2cap_init()
    sm_init()
    sm_set_io_capabilities(3) // IO_CAPABILITY_NO_INPUT_NO_OUTPUT — verified (BleHidPicoW.swift)
    sm_set_authentication_requirements(0x09) // SM_AUTHREQ_BONDING | SM_AUTHREQ_SECURE_CONNECTION — verified

    // Same as BleHidPicoW.swift: profile_data doesn't need permanentCopy()
    // despite att_server_init retaining this pointer long-term — it's a C
    // `.rodata` global with static storage duration, not a Swift
    // `let`/`var` array that could be reallocated, so its address is
    // already stable for the life of the process.
    withUnsafePointer(to: &profile_data) {
        att_server_init($0, nil, nil)
    }

    battery_service_server_init(battery)
    device_information_service_server_init()
    // hids_device_init stores this pointer long-term — must be the
    // permanent copy, not a withUnsafeBufferPointer-scoped one.
    let hidDescStorage = permanentCopy(hidDescriptorKeyboardBytes)
    hidDescriptorKeyboardStorage = hidDescStorage
    hids_device_init(0, hidDescStorage.baseAddress!, UInt16(hidDescStorage.count))

    // gap_advertisements_set_params's direct_address is memcpy'd into
    // hci_stack's own storage synchronously — BTstack does NOT retain this
    // pointer, so a withUnsafeBufferPointer-scoped one is fine here.
    let nullAddr = [UInt8](repeating: 0, count: 6)
    nullAddr.withUnsafeBufferPointer { addrPtr in
        gap_advertisements_set_params(0x0030, 0x0030, 0, 0, addrPtr.baseAddress!, 0x07, 0x00)
    }
    // gap_advertisements_set_data stores this pointer long-term too — must
    // be the permanent copy.
    let advStorage = permanentCopy(advDataBytes)
    advDataStorage = advStorage
    gap_advertisements_set_data(UInt8(advStorage.count), advStorage.baseAddress!)
    gap_advertisements_enable(1)

    hciEventCallbackRegistration.callback = packetHandler
    withUnsafeMutablePointer(to: &hciEventCallbackRegistration) { hci_add_event_handler(UnsafeMutableRawPointer($0)) }
    smEventCallbackRegistration.callback = packetHandler
    withUnsafeMutablePointer(to: &smEventCallbackRegistration) { sm_add_event_handler(UnsafeMutableRawPointer($0)) }
    hids_device_register_packet_handler(packetHandler)

    // Triggers hci.c's internal power-on state machine, which now includes
    // the chipset init sequence wired up in cyw43439BtInit() above. With
    // real PatchRAM data present (cyw43439_patchram.c's
    // brcm_patch_ram_length = 6979 — see the *** STATUS *** comment near
    // the top of this file), this loads the patch before reaching
    // HCI_STATE_WORKING, rather than falling back to the chip's ROM-only
    // HCI command set.
    _ = hci_power_control(1) // HCI_POWER_ON — verified (BleHidPicoW.swift)
}

func send_keyboard_report(_ modifier: UInt8, _ keys: UnsafePointer<UInt8>) {
    pendingReport[0] = modifier
    pendingReport[1] = 0
    for i in 0..<6 { pendingReport[2 + i] = keys[i] }
    reportDirty = true
    if conHandle != hciConHandleInvalid {
        _ = hids_device_request_can_send_now_event(conHandle)
    }
}

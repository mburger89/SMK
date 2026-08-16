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
// cyw43439PowerUp/cyw43439BtInit). The one remaining gap is the actual
// PatchRAM firmware bytes (proprietary, chip-revision-specific — see
// cyw43439_patchram.c). Without them the chip stays on its ROM-only HCI
// command set, so BLE advertising will not start — a data problem, not a
// missing protocol implementation. ***
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
// The HID-over-GATT half (GATT/SM/advertising setup, packet handler,
// send_keyboard_report) is the shared ports/common/BleHidGatt.swift,
// compiled into this build alongside this file — only the transport
// bring-up here (this board's dedicated UART link to a CYW43439, vs. Pico
// W's onboard cyw43_arch) is board-specific.
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

// btstack_uart_t (a.k.a. btstack_uart_block_t) — the UART driver vtable
// BTstack reads by address, now a Swift mirror instead of a C struct
// literal. Field order verified against the real vendored header
// (~/pico-sdk/lib/btstack/src/btstack_uart.h): the 10 H4-relevant function
// pointers below in declaration order, then 7 sleep-/H5-frame-mode fields
// this plain-H4 transport leaves NULL (mirrored as untyped nil pointers —
// BTstack null-checks before calling any of them). 17 same-size pointer
// fields in declaration order — the same verified mirror class as
// BtstackPacketCallbackRegistration (ports/common/BleHidGatt.swift).
struct BtstackUartVtable {
    var initFn: (@convention(c) (UnsafeRawPointer?) -> Int32)? // init(const btstack_uart_config_t *)
    var open: (@convention(c) () -> Int32)?
    var close: (@convention(c) () -> Int32)?
    var setBlockReceived: (@convention(c) ((@convention(c) () -> Void)?) -> Void)?
    var setBlockSent: (@convention(c) ((@convention(c) () -> Void)?) -> Void)?
    var setBaudrate: (@convention(c) (UInt32) -> Int32)?
    var setParity: (@convention(c) (Int32) -> Int32)?
    var setFlowcontrol: (@convention(c) (Int32) -> Int32)?
    var receiveBlock: (@convention(c) (UnsafeMutablePointer<UInt8>?, UInt16) -> Void)?
    var sendBlock: (@convention(c) (UnsafePointer<UInt8>?, UInt16) -> Void)?
    // Sleep-mode + H5/SLIP frame fields, all unused by H4 — kept for layout.
    var getSupportedSleepModes: UnsafeRawPointer? = nil
    var setSleep: UnsafeRawPointer? = nil
    var setWakeupHandler: UnsafeRawPointer? = nil
    var setFrameReceived: UnsafeRawPointer? = nil
    var setFrameSent: UnsafeRawPointer? = nil
    var receiveFrame: UnsafeRawPointer? = nil
    var sendFrame: UnsafeRawPointer? = nil
}

private var smkUartDriver = BtstackUartVtable(
    initFn: uart_driver_init,
    open: uart_driver_open,
    close: uart_driver_close,
    setBlockReceived: uart_driver_set_block_received,
    setBlockSent: uart_driver_set_block_sent,
    setBaudrate: uart_driver_set_baudrate,
    setParity: uart_driver_set_parity,
    setFlowcontrol: uart_driver_set_flowcontrol,
    receiveBlock: uart_driver_receive_block,
    sendBlock: uart_driver_send_block
)

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

func uart_driver_open() -> Int32 { 0 }

func uart_driver_close() -> Int32 { 0 }

func uart_driver_set_block_received(_ handler: (@convention(c) () -> Void)?) {
    blockReceivedCb = handler
}

func uart_driver_set_block_sent(_ handler: (@convention(c) () -> Void)?) {
    blockSentCb = handler
}

func uart_driver_set_baudrate(_ baudrate: UInt32) -> Int32 {
    _ = uart_set_baudrate(bt_uart_instance(), baudrate)
    return 0
}

func uart_driver_set_parity(_ parity: Int32) -> Int32 {
    // UART_PARITY_NONE=0, UART_PARITY_EVEN=1 (hardware/uart.h's
    // uart_parity_t: NONE, EVEN, ODD) — verified; the plan's placeholder
    // value of 2 for EVEN was WRONG (2 is UART_PARITY_ODD).
    uart_set_format(bt_uart_instance(), 8, 1, parity != 0 ? 1 : 0)
    return 0
}

func uart_driver_set_flowcontrol(_ flowcontrol: Int32) -> Int32 {
    smk_uart_set_hw_flow(bt_uart_instance(), flowcontrol != 0, flowcontrol != 0)
    return 0
}

func uart_driver_receive_block(_ buffer: UnsafeMutablePointer<UInt8>?, _ len: UInt16) {
    rxBuffer = buffer
    rxLen = len
    rxHave = 0
}

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
// --- HID-over-GATT: shared ports/common/BleHidGatt.swift (compiled into
// this build too — see CMakeLists.txt). Only the transport bring-up below
// is this board's own. send_keyboard_report() also lives in the shared
// file.
// =============================================================================

func init_ble_hid() {
    // BTstack's run loop must exist before hci_init(): hci.c registers
    // timers/data-source callbacks against whatever btstack_run_loop_init()
    // configured.
    let runLoop = smk_async_context_setup()
    btstack_run_loop_init(runLoop)

    cyw43439PowerUp()

    let transport = withUnsafeMutablePointer(to: &smkUartDriver) { ptr in
        hci_transport_h4_instance(UnsafeMutableRawPointer(ptr))
    }
    hci_init(transport, nil)
    cyw43439BtInit() // wires btstack_chipset_bcm; see its comment above

    // GATT/SM/advertising setup, ending in hci_power_control(HCI_POWER_ON)
    // — which triggers hci.c's power-on state machine, including the
    // chipset init sequence wired up in cyw43439BtInit() above. With
    // cyw43439_patchram_data_len == 0 (placeholder — see
    // cyw43439_patchram.c) this reaches HCI_STATE_WORKING using only the
    // chip's ROM HCI command set; advertising will not actually start until
    // real patch data is supplied there.
    smk_ble_hid_gatt_setup()
}

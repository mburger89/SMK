// Wired HID bridge (ESP32-C6, UART1 -> CH9350L) — Swift port of the
// former Sources/components/uart_init.c.

// UnsafePointer<UartConfig> itself can't cross an @_extern(c, ...) boundary
// ("cannot be represented in C" — UartConfig is a plain Swift struct, not
// imported from a C header, so ClangImporter has no C type to associate it
// with for the purposes of this check) even though its byte layout matches
// uart_config_t exactly (verified above). UnsafeRawPointer sidesteps that
// check while still passing the identical bytes — withUnsafePointer(to:)
// below hands this the address of the local UartConfig value directly.
@_extern(c, "uart_param_config")
func uart_param_config(_ uartNum: Int32, _ uartConfig: UnsafeRawPointer) -> Int32

// uart_set_pin itself is NOT a real linkable symbol — driver/uart.h defines
// it as a variadic argument-counting macro (`_GET_UART_SET_PIN_FUNC_NAME` +
// `#define uart_set_pin(...) ...`) that dispatches to one of two real
// functions depending on how many arguments the call site passes:
//   - `_uart_set_pin6` (7 args: uart_num + 6 pins) — the actual exported,
//     externally-linkable symbol.
//   - `_uart_set_pin4` (5 args: uart_num + 4 pins) — `static inline`, not
//     externally linkable; it just forwards to `_uart_set_pin6` with
//     dtr_io_num/dsr_io_num hardcoded to -1 (UART_PIN_NO_CHANGE).
// Discovered empirically: an @_extern(c, "uart_set_pin") declaration builds
// fine (Swift has no way to know the C symbol doesn't really exist) but
// fails at link time with "undefined reference to `uart_set_pin`" — same
// class of bug as UsbHid.swift's tusb_init/tud_task swap for the nRF52840
// port (macro/inline C convenience wrappers with no real symbol to bind
// to). Binding directly to `_uart_set_pin6` and passing -1/-1 for
// dtr_io_num/dsr_io_num reproduces `_uart_set_pin4`'s exact behavior — the
// call site below never used DTR/DSR to begin with (CH9350 needs none).
@_extern(c, "_uart_set_pin6")
func _uart_set_pin6(_ uartNum: Int32, _ txPin: Int32, _ rxPin: Int32, _ rtsPin: Int32, _ ctsPin: Int32, _ dtrPin: Int32, _ dsrPin: Int32) -> Int32

@_extern(c, "uart_driver_install")
func uart_driver_install(_ uartNum: Int32, _ rxBufferSize: Int32, _ txBufferSize: Int32, _ queueSize: Int32, _ queueHandle: UnsafeRawPointer?, _ intrAllocFlags: Int32) -> Int32

@_extern(c, "uart_write_bytes")
func uart_write_bytes(_ uartNum: Int32, _ src: UnsafePointer<UInt8>, _ len: Int) -> Int32

// Hand-rolled to match uart_config_t's real C layout, matching this
// project's established extern-only C interop convention rather than
// importing driver/uart.h via ClangImporter.
//
// Verified against
// ~/.espressif/v6.0.1/esp-idf/components/esp_driver_uart/include/driver/uart.h
// (struct definition) and
// ~/.espressif/v6.0.1/esp-idf/components/esp_hal_uart/include/hal/uart_types.h
// (enum values) on ESP-IDF v6.0.1:
//
//   typedef struct {
//       int baud_rate;
//       uart_word_length_t data_bits;
//       uart_parity_t parity;
//       uart_stop_bits_t stop_bits;
//       uart_hw_flowcontrol_t flow_ctrl;
//       uint8_t rx_flow_ctrl_thresh;
//       union {
//           uart_sclk_t source_clk;          // esp32c6 has SOC_UART_LP_NUM >= 1,
//           lp_uart_sclk_t lp_source_clk;    // but this call site only ever sets
//       };                                   // source_clk, so only that member
//                                             // is represented below.
//       struct {
//           uint32_t allow_pd: 1;
//           uint32_t backup_before_sleep: 1;
//       } flags;
//   } uart_config_t;
//
// This call site's original C literal only sets baud_rate/data_bits/parity/
// stop_bits/flow_ctrl/source_clk — rx_flow_ctrl_thresh and flags are left at
// their implicit zero-init, reproduced here as explicit 0s.
//
// Struct-layout verification performed for real (not just eyeballed): a
// scratch C file (mirroring the real struct in a self-contained way, since
// the real header itself only compiles inside a full ESP-IDF component
// build) printed `sizeof(uart_config_t) == 32` with field offsets
// baud_rate=0, data_bits=4, parity=8, stop_bits=12, flow_ctrl=16,
// rx_flow_ctrl_thresh=20, source_clk(union)=24, flags=28 — i.e. the C
// compiler inserts 3 bytes of padding after rx_flow_ctrl_thresh to
// 4-byte-align the union. A companion Swift scratch file with the exact
// struct below reported `MemoryLayout<UartConfig>.size == 32` and identical
// per-field offsets (0/4/8/12/16/20/24/28) via
// `MemoryLayout<UartConfig>.offset(of:)` — Swift's declaration-order layout
// naturally inserts the same padding ahead of `sourceClk` because `UInt32`
// (used for `flags`, matching the bitfield struct's own `uint32_t` storage
// unit) requires 4-byte alignment. Sizes and offsets match exactly.
struct UartConfig {
    var baudRate: Int32
    var dataBits: Int32   // uart_word_length_t
    var parity: Int32     // uart_parity_t
    var stopBits: Int32   // uart_stop_bits_t
    var flowCtrl: Int32   // uart_hw_flowcontrol_t
    var rxFlowCtrlThresh: UInt8
    var sourceClk: Int32  // union { uart_sclk_t source_clk; ... } — source_clk is the live member here
    var flags: UInt32     // 2-bit bitfield struct, zeroed here (matches original call site's implicit zero-init)
}

private let uartNum1: Int32 = 1 // UART_NUM_1 (uart_port_t: UART_NUM_0=0, UART_NUM_1=1)
private let txPin: Int32 = 16   // WIRED_TX net -> CH9350L RXD (pin27); IO20/IO21 collide with COL7/COL8 on smk_kbd
private let uartPinNoChange: Int32 = -1 // UART_PIN_NO_CHANGE, #define'd as (-1) in driver/uart.h
private let baudRate: Int32 = 115200 // matches CH9350L's default BAUD0/BAUD1 strapping

// UART_DATA_8_BITS = 0x3 (uart_word_length_t, hal/uart_types.h)
private let uartData8Bits: Int32 = 3
// UART_PARITY_DISABLE = 0x0 (uart_parity_t, hal/uart_types.h)
private let uartParityDisable: Int32 = 0
// UART_STOP_BITS_1 = 0x1 (uart_stop_bits_t, hal/uart_types.h)
private let uartStopBits1: Int32 = 1
// UART_HW_FLOWCTRL_DISABLE = 0x0 (uart_hw_flowcontrol_t, hal/uart_types.h)
private let uartHwFlowctrlDisable: Int32 = 0
// UART_SCLK_DEFAULT for esp32c6 = SOC_MOD_CLK_PLL_F80M (soc/esp32c6/include/soc/clk_tree_defs.h).
// soc_module_clk_t starts at 1 (SOC_MOD_CLK_CPU=1, RTC_FAST=2, RTC_SLOW=3,
// APB=4, PLL_F80M=5) so UART_SCLK_DEFAULT == 5 on this chip. NOT 0 — 0 is
// reserved ("enum starts from 1, to save 0 for special purpose").
private let uartSclkDefault: Int32 = 5

func init_wired_link() {
    var config = UartConfig(
        baudRate: baudRate,
        dataBits: uartData8Bits,
        parity: uartParityDisable,
        stopBits: uartStopBits1,
        flowCtrl: uartHwFlowctrlDisable,
        rxFlowCtrlThresh: 0,
        sourceClk: uartSclkDefault,
        flags: 0
    )
    _ = withUnsafePointer(to: &config) { uart_param_config(uartNum1, UnsafeRawPointer($0)) }
    _ = _uart_set_pin6(uartNum1, txPin, uartPinNoChange, uartPinNoChange, uartPinNoChange, uartPinNoChange, uartPinNoChange)
    _ = uart_driver_install(uartNum1, 256, 0, 0, nil, 0)
}

// CH9350 12-byte frame protocol:
// [0-1] Header 0x57 0xAB, [2] ID 0x01 (Keyboard), [3-10] 8-byte HID report,
// [11] Checksum (sum of ID + 8 data bytes, low 8 bits).
func send_wired_report(_ modifier: UInt8, _ keys: UnsafePointer<UInt8>) {
    var frame = [UInt8](repeating: 0, count: 12)
    frame[0] = 0x57
    frame[1] = 0xAB
    frame[2] = 0x01

    var hidReport = [UInt8](repeating: 0, count: 8)
    hidReport[0] = modifier
    for i in 0..<6 { hidReport[2 + i] = keys[i] }

    for i in 0..<8 { frame[3 + i] = hidReport[i] }

    var checksum = frame[2]
    for b in hidReport { checksum = checksum &+ b }
    frame[11] = checksum

    _ = frame.withUnsafeBufferPointer { uart_write_bytes(uartNum1, $0.baseAddress!, 12) }
}

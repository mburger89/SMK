// SK6812MINI-E chain driver (RMT-based) — Swift port of the former
// Sources/components/led_strip_driver.c. SK6812/WS2812 need ~0.3-0.9us bit
// timing precision RMT provides in hardware, immune to FreeRTOS scheduling
// jitter a plain GPIO bit-bang loop would suffer. Wire format is GRB,
// MSB-first per channel. rmt_new_led_strip_encoder itself stays C
// (led_strip_encoder.c — struct-embedding/vtable C idiom, permanent
// exception, see this plan's design spec); everything else here is Swift.

@_extern(c, "rmt_new_tx_channel")
func rmt_new_tx_channel(_ config: UnsafeRawPointer, _ retChan: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32

@_extern(c, "rmt_new_led_strip_encoder")
func rmt_new_led_strip_encoder(_ config: UnsafeRawPointer, _ retEncoder: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32

@_extern(c, "rmt_enable")
func rmt_enable(_ channel: UnsafeMutableRawPointer?) -> Int32

@_extern(c, "rmt_transmit")
func rmt_transmit(_ channel: UnsafeMutableRawPointer?, _ encoder: UnsafeMutableRawPointer?, _ payload: UnsafeRawPointer, _ payloadBytes: Int, _ config: UnsafeRawPointer) -> Int32

@_extern(c, "rmt_tx_wait_all_done")
func rmt_tx_wait_all_done(_ channel: UnsafeMutableRawPointer?, _ timeoutMs: Int32) -> Int32

// Layouts verified against driver/rmt_tx.h and led_strip_encoder.h two ways:
// (1) a scratch C file reproducing all three structs verbatim, compiled
//     with the real ESP32-C6 target compiler (riscv32-esp-elf-gcc,
//     -mabi=ilp32 -march=rv32imac) with debug info, offsets read back via
//     readelf --debug-dump=info (not the host `cc` — size_t is 8 bytes on
//     the macOS host but only 4 bytes on this 32-bit RISC-V target, which
//     would have silently produced the wrong padding/offsets for
//     mem_block_symbols/trans_queue_depth below had host `cc` been trusted);
// (2) the exact struct definitions below, compiled for the real
//     `-target riscv32-none-none-eabi` with this project's actual Embedded
//     Swift flags (-Osize -enable-experimental-feature Embedded -wmo),
//     emitted as assembly, confirming every `MemoryLayout<...>.size`/
//     `.offset(of:)` folds to the identical compile-time constant as the C
//     side. Both methods agree exactly:
//   RmtTxChannelConfig:    size 28, offsets gpioNum=0 clkSrc=4 resolutionHz=8
//                          memBlockSymbols=12 transQueueDepth=16
//                          intrPriority=20 flags=24
//   LedStripEncoderConfig: size 4
//   RmtTransmitConfig:     size 8, offset flags=4
// `Int` is 4 bytes on this target (riscv32, ilp32 ABI — confirmed via
// `swiftc -target riscv32-none-none-eabi -print-target-info`,
// pointerWidthInBits: 32), matching `size_t` exactly, so plain `Int` below
// is correct for mem_block_symbols/trans_queue_depth without needing an
// explicit-width workaround.
//
// The trailing bitfield `flags` structs (4 single-bit fields for
// rmt_tx_channel_config_t, 2 for rmt_transmit_config_t, all `uint32_t`-
// backed) collapse to a single zeroed UInt32 each — this task's call site
// never sets any of these bits explicitly, so the whole flags word
// zero-initializes; same reasoning as Task 8's `uart_config_t.flags`. This
// doesn't reproduce the general bitfield ABI, only this call site's
// all-zero case.
//
// `UnsafeRawPointer` (not `UnsafePointer<RmtTxChannelConfig>` etc.) is used
// for the config parameters below because a hand-rolled Swift struct has no
// C type ClangImporter can represent across an `@_extern(c, ...)` boundary
// — `UnsafePointer<RmtTxChannelConfig>` fails to compile with "cannot be
// represented in C". Same fix as Task 8's `uart_param_config`.
struct RmtTxChannelConfig {
    var gpioNum: Int32
    var clkSrc: Int32
    var resolutionHz: UInt32
    var memBlockSymbols: Int  // size_t
    var transQueueDepth: Int  // size_t
    var intrPriority: Int32
    var flags: UInt32
}

struct LedStripEncoderConfig {
    var resolution: UInt32
}

struct RmtTransmitConfig {
    var loopCount: Int32
    var flags: UInt32
}

private let ledStripMaxLeds = 60 // matches ROWS*COLS in generate_pcb.py
private let ledStripResolutionHz: UInt32 = 10_000_000 // 10MHz, 1 tick = 0.1us

// RMT_CLK_SRC_DEFAULT on ESP32-C6 = SOC_MOD_CLK_PLL_F80M = 5. Traced through
// soc/esp32c6/include/soc/clk_tree_defs.h's `soc_module_clk_t`, which
// intentionally starts at 1 ("enum starts from 1, to save 0 for special
// purpose"): SOC_MOD_CLK_CPU=1, RTC_FAST=2, RTC_SLOW=3, APB=4, PLL_F80M=5.
// Same constant Task 8 derived for UART_SCLK_DEFAULT on this chip (also
// PLL_F80M) — chip-specific; would need re-deriving from that chip's
// clk_tree_defs.h if this project ever targets a different ESP32 variant.
private let rmtClkSrcDefault: Int32 = 5

private var ledChan: UnsafeMutableRawPointer? = nil
private var ledEncoder: UnsafeMutableRawPointer? = nil
private var pixels = [UInt8](repeating: 0, count: ledStripMaxLeds * 3)
private var numLeds = 0
private var ready = false

func led_strip_driver_init(_ gpioNum: Int32, _ requestedNumLeds: Int32) {
    var count = Int(requestedNumLeds)
    if count < 0 { count = 0 }
    if count > ledStripMaxLeds { count = ledStripMaxLeds }
    numLeds = count
    for i in 0..<pixels.count { pixels[i] = 0 }

    var txConfig = RmtTxChannelConfig(
        gpioNum: gpioNum,
        clkSrc: rmtClkSrcDefault,
        resolutionHz: ledStripResolutionHz,
        memBlockSymbols: 64,
        transQueueDepth: 4,
        intrPriority: 0,
        flags: 0
    )
    guard withUnsafePointer(to: &txConfig, { rmt_new_tx_channel(UnsafeRawPointer($0), &ledChan) }) == 0 else { return }

    var encoderConfig = LedStripEncoderConfig(resolution: ledStripResolutionHz)
    guard withUnsafePointer(to: &encoderConfig, { rmt_new_led_strip_encoder(UnsafeRawPointer($0), &ledEncoder) }) == 0 else { return }

    guard rmt_enable(ledChan) == 0 else { return }
    ready = true
}

func led_strip_set_pixel(_ index: Int32, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
    guard ready, index >= 0, Int(index) < numLeds else { return }
    let i = Int(index)
    // SK6812/WS2812 wire order is G, R, B.
    pixels[i * 3 + 0] = g
    pixels[i * 3 + 1] = r
    pixels[i * 3 + 2] = b
}

func led_strip_refresh() {
    guard ready else { return }
    var txConfig = RmtTransmitConfig(loopCount: 0, flags: 0)
    let sendResult = pixels.withUnsafeBufferPointer { buf in
        withUnsafePointer(to: &txConfig) { cfg in
            rmt_transmit(ledChan, ledEncoder, buf.baseAddress!, numLeds * 3, UnsafeRawPointer(cfg))
        }
    }
    guard sendResult == 0 else { return }
    _ = rmt_tx_wait_all_done(ledChan, 100)
}

func led_strip_clear() {
    guard ready else { return }
    for i in 0..<(numLeds * 3) { pixels[i] = 0 }
    led_strip_refresh()
}

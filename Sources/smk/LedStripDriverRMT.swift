// SK6812MINI-E chain driver (RMT-based) — Swift port of the former
// Sources/components/led_strip_driver.c, now including the custom RMT
// encoder that used to be Sources/components/led_strip_encoder.c (deleted).
// SK6812/WS2812 need ~0.3-0.9us bit timing precision RMT provides in
// hardware, immune to FreeRTOS scheduling jitter a plain GPIO bit-bang loop
// would suffer. Wire format is GRB, MSB-first per channel.

@_extern(c, "rmt_new_tx_channel")
func rmt_new_tx_channel(_ config: UnsafeRawPointer, _ retChan: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32

@_extern(c, "rmt_enable")
func rmt_enable(_ channel: UnsafeMutableRawPointer?) -> Int32

@_extern(c, "rmt_transmit")
func rmt_transmit(_ channel: UnsafeMutableRawPointer?, _ encoder: UnsafeMutableRawPointer?, _ payload: UnsafeRawPointer, _ payloadBytes: Int, _ config: UnsafeRawPointer) -> Int32

@_extern(c, "rmt_tx_wait_all_done")
func rmt_tx_wait_all_done(_ channel: UnsafeMutableRawPointer?, _ timeoutMs: Int32) -> Int32

// Layouts verified against driver/rmt_tx.h (and the then-extant
// led_strip_encoder.h) two ways:
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

struct RmtTransmitConfig {
    var loopCount: Int32
    var flags: UInt32
}

// ===========================================================================
// Custom led-strip RMT encoder — Swift port of the former
// Sources/components/led_strip_encoder.c (itself adapted from ESP-IDF's
// examples/peripherals/rmt/led_strip reference encoder).
// ===========================================================================
//
// The RMT driver drives a user encoder through a 3-function-pointer vtable
// (`struct rmt_encoder_t`, driver/rmt_encoder.h — field order encode,
// reset, del, read straight from the real ESP-IDF v6.0.1 header). The C
// original embedded that vtable as the first member of a container struct
// and recovered its state via __containerof; this port sidesteps the
// container-layout question entirely: the driver only ever sees a bare
// vtable allocated via rmt_alloc_encoder_mem(), and the encoder's state
// (sub-encoder handles, data/reset-phase flag, reset symbol) lives in
// module-level Swift globals — valid because this module creates exactly
// one led-strip encoder, ever (single fixed chain per board).
//
// The vtable mirror below is 3 same-size C function pointers in declaration
// order — the same verified mirror class as RmtTxChannelConfig above and
// BtstackPacketCallbackRegistration in ports/common/BleHidGatt.swift.
//
// ISR/IRAM note: encode/reset are called from the RMT ISR. This project's
// sdkconfig has CONFIG_RMT_ENCODER_FUNC_IN_IRAM=y, so the C versions were
// IRAM-placed; the Swift versions reproduce that with @_section(".iram1.*")
// (SymbolLinkageMarkers, enabled in main/CMakeLists.txt), which the ESP-IDF
// linker fragment collects into IRAM like any IRAM_ATTR function.
// CONFIG_RMT_ISR_IRAM_SAFE is NOT set, so this is the same
// performance-placement (not flash-cache-off correctness) the C had.

struct RmtEncoderVtable {
    var encode: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeRawPointer?, Int, UnsafeMutablePointer<UInt32>?) -> Int)?
    var reset: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?
    var del: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?
}

// rmt_bytes_encoder_config_t (driver/rmt_encoder.h): two rmt_symbol_word_t
// (32-bit bitfield unions, packed manually via rmtSymbolWord below) + a
// 1-bit flags word — three UInt32s in declaration order.
struct RmtBytesEncoderConfig {
    var bit0: UInt32
    var bit1: UInt32
    var flags: UInt32 // bit 0 = msb_first
}

@_extern(c, "rmt_alloc_encoder_mem")
func rmt_alloc_encoder_mem(_ size: Int) -> UnsafeMutableRawPointer?

@_extern(c, "rmt_new_bytes_encoder")
func rmt_new_bytes_encoder(_ config: UnsafeRawPointer, _ retEncoder: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32

@_extern(c, "rmt_new_copy_encoder")
func rmt_new_copy_encoder(_ config: UnsafeRawPointer, _ retEncoder: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32

// rmt_encode_state_t (4-byte enum on this ABI): bit flags.
private let rmtEncodingComplete: UInt32 = 1 << 0
private let rmtEncodingMemFull: UInt32 = 1 << 1

// rmt_symbol_word_t bit layout (hal/rmt_types.h: duration0 [14:0],
// level0 [15], duration1 [30:16], level1 [31]).
private func rmtSymbolWord(_ level0: UInt32, _ duration0: UInt32, _ level1: UInt32, _ duration1: UInt32) -> UInt32 {
    (duration0 & 0x7FFF) | (level0 << 15) | ((duration1 & 0x7FFF) << 16) | (level1 << 31)
}

// Single-instance encoder state (see header note above for why globals
// replace the C container struct).
private var stripBytesEncoder: UnsafeMutableRawPointer? = nil
private var stripCopyEncoder: UnsafeMutableRawPointer? = nil
private var stripEncodePhase: Int32 = 0 // 0 = RGB data, 1 = reset code
private var stripResetCode: UInt32 = 0  // rmt_symbol_word_t, address stable (Swift global)

@inline(__always)
private func subEncode(_ enc: UnsafeMutableRawPointer, _ channel: UnsafeMutableRawPointer?, _ data: UnsafeRawPointer?, _ size: Int, _ state: UnsafeMutablePointer<UInt32>) -> Int {
    enc.assumingMemoryBound(to: RmtEncoderVtable.self).pointee.encode!(enc, channel, data, size, state)
}

// The encode callback the RMT driver invokes (ISR context — no blocking
// APIs, no allocation). Faithful translation of the C original's
// two-phase fall-through state machine: phase 0 streams the GRB payload
// through the bytes encoder, phase 1 appends the SK6812 reset pulse via
// the copy encoder, yielding whenever the RMT symbol memory fills.
@_section(".iram1.smk_led_enc")
private func ledStripEncodeCallback(_ encoder: UnsafeMutableRawPointer?, _ channel: UnsafeMutableRawPointer?, _ primaryData: UnsafeRawPointer?, _ dataSize: Int, _ retState: UnsafeMutablePointer<UInt32>?) -> Int {
    guard let retState else { return 0 }
    guard let bytesEnc = stripBytesEncoder, let copyEnc = stripCopyEncoder else {
        retState.pointee = rmtEncodingComplete
        return 0
    }

    var state: UInt32 = 0
    var sessionState: UInt32 = 0
    var encodedSymbols = 0

    if stripEncodePhase == 0 { // send RGB data
        encodedSymbols += subEncode(bytesEnc, channel, primaryData, dataSize, &sessionState)
        if sessionState & rmtEncodingComplete != 0 {
            stripEncodePhase = 1 // switch to reset code once the payload session finished
        }
        if sessionState & rmtEncodingMemFull != 0 {
            retState.pointee = state | rmtEncodingMemFull // yield: no free space for encoding artifacts
            return encodedSymbols
        }
    }
    if stripEncodePhase == 1 { // send reset code
        sessionState = 0
        encodedSymbols += withUnsafeMutablePointer(to: &stripResetCode) { resetPtr in
            subEncode(copyEnc, channel, UnsafeRawPointer(resetPtr), MemoryLayout<UInt32>.size, &sessionState)
        }
        if sessionState & rmtEncodingComplete != 0 {
            stripEncodePhase = 0 // back to the initial encoding session
            state |= rmtEncodingComplete
        }
        if sessionState & rmtEncodingMemFull != 0 {
            state |= rmtEncodingMemFull
        }
    }
    retState.pointee = state
    return encodedSymbols
}

@_section(".iram1.smk_led_enc_rst")
private func ledStripEncoderResetCallback(_ encoder: UnsafeMutableRawPointer?) -> Int32 {
    if let bytesEnc = stripBytesEncoder {
        _ = bytesEnc.assumingMemoryBound(to: RmtEncoderVtable.self).pointee.reset?(bytesEnc)
    }
    if let copyEnc = stripCopyEncoder {
        _ = copyEnc.assumingMemoryBound(to: RmtEncoderVtable.self).pointee.reset?(copyEnc)
    }
    stripEncodePhase = 0
    return 0
}

// Never called in this firmware (the strip encoder lives forever), present
// for vtable completeness. Deliberately does NOT free: this port's state is
// module globals, and the sub-encoders are only torn down at delete time in
// the generic C original — a code path this single-instance driver has no
// use for.
private func ledStripEncoderDelCallback(_ encoder: UnsafeMutableRawPointer?) -> Int32 {
    0
}

// Builds the custom encoder: a bytes encoder carrying the WS2812/SK6812
// shared T0H/T0L/T1H/T1L bit timing, a copy encoder for the reset pulse,
// and the vtable handed back to rmt_transmit(). Returns nil on any driver
// error, matching the C original's cleanup-and-fail behavior.
private func newLedStripEncoder(resolution: UInt32) -> UnsafeMutableRawPointer? {
    // WS2812/SK6812 timing (both parts share the same T0H/T0L/T1H/T1L
    // spec): T0H=0.3us/T0L=0.9us, T1H=0.9us/T1L=0.3us.
    let ticksPerUs = resolution / 1_000_000
    var bytesConfig = RmtBytesEncoderConfig(
        bit0: rmtSymbolWord(1, ticksPerUs * 3 / 10, 0, ticksPerUs * 9 / 10),
        bit1: rmtSymbolWord(1, ticksPerUs * 9 / 10, 0, ticksPerUs * 3 / 10),
        flags: 1 // msb_first
    )
    var bytesEnc: UnsafeMutableRawPointer? = nil
    guard withUnsafePointer(to: &bytesConfig, { rmt_new_bytes_encoder(UnsafeRawPointer($0), &bytesEnc) }) == 0,
          let bytesEncoder = bytesEnc else { return nil }

    // rmt_copy_encoder_config_t is an empty struct — the driver never reads
    // through the pointer, but requires it non-NULL; a zero byte satisfies
    // both.
    var copyConfigDummy: UInt8 = 0
    var copyEnc: UnsafeMutableRawPointer? = nil
    guard withUnsafePointer(to: &copyConfigDummy, { rmt_new_copy_encoder(UnsafeRawPointer($0), &copyEnc) }) == 0,
          let copyEncoder = copyEnc else { return nil }

    // SK6812MINI-E datasheet (datasheets/SK6812MINI-E.pdf, section 10)
    // specifies a 200us MINIMUM reset low time — notably longer than
    // generic WS2812's ~50us. 280us gives comfortable margin above spec
    // (the symbol's two halves are 140us each).
    let resetTicks = ticksPerUs * 280 / 2
    stripResetCode = rmtSymbolWord(0, resetTicks, 0, resetTicks)
    stripBytesEncoder = bytesEncoder
    stripCopyEncoder = copyEncoder
    stripEncodePhase = 0

    // rmt_alloc_encoder_mem rather than a plain Swift allocation so the
    // vtable lands in the same memory class the RMT driver expects for
    // encoders (heap_caps internal RAM; would follow the driver if a future
    // config moves encoder allocations).
    guard let mem = rmt_alloc_encoder_mem(MemoryLayout<RmtEncoderVtable>.size) else { return nil }
    let vtable = mem.assumingMemoryBound(to: RmtEncoderVtable.self)
    vtable.pointee.encode = ledStripEncodeCallback
    vtable.pointee.reset = ledStripEncoderResetCallback
    vtable.pointee.del = ledStripEncoderDelCallback
    return mem
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
    numLeds = smkLedStripClampCount(requestedNumLeds, maxLeds: ledStripMaxLeds)
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

    ledEncoder = newLedStripEncoder(resolution: ledStripResolutionHz)
    guard ledEncoder != nil else { return }

    guard rmt_enable(ledChan) == 0 else { return }
    ready = true
}

func led_strip_set_pixel(_ index: Int32, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
    guard ready else { return }
    smkLedStripSetPixel(&pixels, index: index, numLeds: numLeds, r: r, g: g, b: b)
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
    // 100 here is milliseconds (rmt_tx_wait_all_done's real signature takes
    // a ms timeout directly) — this is the intended value, not an
    // accidental deviation from the deleted C original. That C code passed
    // pdMS_TO_TICKS(100), which at this project's CONFIG_FREERTOS_HZ=100
    // evaluated to 10 — a latent unit bug giving a 10ms timeout instead of
    // the intended 100ms. This Swift port fixes it.
    _ = rmt_tx_wait_all_done(ledChan, 100)
}

func led_strip_clear() {
    guard ready else { return }
    for i in 0..<(numLeds * 3) { pixels[i] = 0 }
    led_strip_refresh()
}

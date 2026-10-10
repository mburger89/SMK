// RP2040 / RP2350 GPIO register access via the SIO (Single-cycle IO) block.
//
// This is the RP2040/RP2350 counterpart to the ESP32 `Sources/smk/GPIORegisters.swift`.
// It deliberately exposes the SAME `outSet` / `outClear` / `input` API (with
// bit position == GPIO number) so that the shared `KeyMatrix.scan()` compiles
// and runs unchanged across both platforms.
//
// The SIO GPIO register block (base address and offsets below) is identical
// between RP2040 and RP2350, so this one file covers both chips unchanged.
//
// SIO base address: 0xD000_0000
//   0x004  GPIO_IN       (read)
//   0x010  GPIO_OUT      (read/write)        -- not touched here
//   0x014  GPIO_OUT_SET  (atomic set bits)
//   0x018  GPIO_OUT_CLR  (atomic clear bits)
//
// NOTE: The SIO only drives/reads the pin *level*. Each pad must first be
// muxed to the SIO function and have its direction / pull-ups configured.
// That one-time setup is done in `GPIOInit.swift` via the pico-sdk.
//
// Accesses go through swift-mmio (third_party/swift-mmio, compiled flat
// into this target — see cmake/SwiftMMIO.cmake), so every read/write is a
// real 32-bit volatile load/store. The previous `.pointee` version was not:
// LLVM was free to hoist, merge or delete those accesses (see CLAUDE.md's
// register-polling note).

@RegisterBlock
struct SIOGPIO {
    @RegisterBlock(offset: 0x004) var gpioIn: Register<GPIOWord>
    @RegisterBlock(offset: 0x014) var gpioOutSet: Register<GPIOWord>
    @RegisterBlock(offset: 0x018) var gpioOutClr: Register<GPIOWord>
}

// One whole 32-bit word: the matrix code works in raw pin bitmasks, so no
// per-pin bit fields are modelled.
@Register(bitWidth: 32)
struct GPIOWord {
    @ReadWrite(bits: 0..<32, as: UInt32.self) var value: VALUE
}

struct GPIORegisters {
    static let base: UInt = 0xD0000000 // SIO

    let sio: SIOGPIO

    init(address: UInt) {
        self.sio = SIOGPIO(unsafeAddress: address)
    }

    // 0x014: GPIO_OUT_SET — writing a 1 sets the corresponding output high.
    // The getter reads GPIO_OUT_SET itself, exactly as the pre-swift-mmio
    // code did.
    var outSet: UInt32 {
        get { sio.gpioOutSet.read().value }
        nonmutating set { sio.gpioOutSet.write { $0.value = newValue } }
    }

    // 0x018: GPIO_OUT_CLR — writing a 1 drives the corresponding output low.
    // The getter reads GPIO_OUT_CLR itself, exactly as the pre-swift-mmio
    // code did.
    var outClear: UInt32 {
        get { sio.gpioOutClr.read().value }
        nonmutating set { sio.gpioOutClr.write { $0.value = newValue } }
    }

    // 0x004: GPIO_IN — current input level of every GPIO (bit == GPIO number).
    var input: UInt32 {
        get { sio.gpioIn.read().value }
    }
}

// Instantiate the bank at the RP2040 SIO base address.
let gpio = GPIORegisters(address: GPIORegisters.base)

// Matrix settle delay (see smkMatrixSettleMicros in KeyMatrix.swift).
// busy_wait_us_32 is pico-sdk's out-of-line busy-wait on the 1 MHz system
// timer (hardware_timer, linked via pico_stdlib; same on RP2040 and RP2350),
// so it is independent of the CPU clock. It waits until the timer has
// advanced by the requested count, so the real delay is between
// (smkMatrixSettleMicros - 1) and smkMatrixSettleMicros µs, i.e. 4-5 µs —
// still well over the ~1.6 µs worst-case pull-up recovery. The bridging header
// imports no pico-sdk header, hence the @_extern binding.
@_extern(c, "busy_wait_us_32")
func busy_wait_us_32(_ delayUs: UInt32)

// @inline(never) keeps this a distinct symbol that tools/build_all.sh
// --check-polls can find (scan() must call it; it must call busy_wait_us_32).
@inline(never)
func smkSettleDelay() {
    busy_wait_us_32(smkMatrixSettleMicros)
}

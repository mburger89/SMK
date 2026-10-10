// nRF52840 GPIO (P0) register access — same outSet/outClear/input API
// as Sources/smk/GPIORegisters.swift (ESP32-C6) and
// ports/rp2040/GPIORegisters.swift (RP2040/RP2350). P0 only (GPIO 0-31) —
// this board's matrix fits comfortably within P0 (a 5x12 matrix needs 17
// pins), so P1 (pins 32-47) is unused and not wired up here.
//
// Register offsets verified against Nordic's nRF52840 Product
// Specification during this port's feasibility spike:
// docs/superpowers/specs/2026-08-09-nrf52840-support-design.md.
//
// P0 base address: 0x5000_0000
//   0x504  OUT      (read/write)        -> word index 321 (not used here)
//   0x508  OUTSET   (atomic set bits)   -> word index 322
//   0x50C  OUTCLR   (atomic clear bits) -> word index 323
//   0x510  IN       (read)              -> word index 324
//   0x700  PIN_CNF[0..31] (one 32-bit word per pin, stride 4) — written
//          by GPIOInit.swift
//
// Accesses go through swift-mmio (third_party/swift-mmio, compiled flat
// into this target — see cmake/SwiftMMIO.cmake), so every read/write is a
// real volatile load/store. The previous `.pointee` version was not: LLVM
// was free to hoist, merge or delete those accesses (see CLAUDE.md's
// register-polling note).

@RegisterBlock
struct GPIOPort {
    @RegisterBlock(offset: 0x508) var outset: Register<GPIOWord>
    @RegisterBlock(offset: 0x50C) var outclr: Register<GPIOWord>
    @RegisterBlock(offset: 0x510) var input: Register<GPIOWord>
    @RegisterBlock(offset: 0x700, stride: 4, count: 32) var pinCnf: RegisterArray<GPIOWord>
}

// One whole 32-bit word: the matrix code works in raw pin bitmasks, so no
// per-pin bit fields are modelled.
@Register(bitWidth: 32)
struct GPIOWord {
    @ReadWrite(bits: 0..<32, as: UInt32.self) var value: VALUE
}

struct GPIORegisters {
    static let base: UInt = 0x50000000 // P0

    let port: GPIOPort

    init(address: UInt) {
        self.port = GPIOPort(unsafeAddress: address)
    }

    // 0x508: OUTSET — writing a 1 sets the corresponding output high.
    // Reading OUTSET returns the OUT latch (same as the old getter, which
    // read this register).
    var outSet: UInt32 {
        get { port.outset.read().value }
        nonmutating set { port.outset.write { $0.value = newValue } }
    }

    // 0x50C: OUTCLR — writing a 1 drives the corresponding output low.
    var outClear: UInt32 {
        get { port.outclr.read().value }
        nonmutating set { port.outclr.write { $0.value = newValue } }
    }

    // 0x510: IN — current input level of every P0 pin (bit == GPIO number).
    var input: UInt32 {
        get { port.input.read().value }
    }
}

// Instantiate the bank at the nRF52840 P0 base address.
let gpio = GPIORegisters(address: GPIORegisters.base)

// Matrix settle delay (see smkMatrixSettleMicros in KeyMatrix.swift). This
// port has no calibrated microsecond delay to call, so it spins on volatile
// reads of the GPIO input register (swift-mmio: each one is a real bus
// access LLVM cannot delete, unlike the empty loop this replaced).
//
// nRF52840: the CPU always runs at 64 MHz (HFCLK, from HFINT or HFXO; the
// core clock is not configurable). The vendored MDK's system_nrf52.c
// (compiled in via ports/nrf52840/CMakeLists.txt) records the same value as
// SystemCoreClock = __SYSTEM_CLOCK_64M.
private let smkSettleCpuMHz: UInt32 = 64

// Each iteration is a volatile load plus a decrement and a taken backward
// branch, so it takes at least 2 cycles (in practice more: the bus access
// alone is >= 2). Sizing the count for 2 cycles per iteration means the
// real delay is at least smkMatrixSettleMicros; overshooting is harmless,
// undershooting is the bug this exists to fix.
//
// @inline(never) keeps this a distinct symbol that tools/build_all.sh
// --check-polls can find (scan() must call it; its loop must survive).
@inline(never)
func smkSettleDelay() {
    var remaining = smkMatrixSettleMicros * smkSettleCpuMHz / 2
    while remaining != 0 {
        _ = gpio.input
        remaining &-= 1
    }
}

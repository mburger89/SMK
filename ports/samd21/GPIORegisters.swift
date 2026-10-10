// SAMD21 GPIO register access — PORT group A only. Same single-bank
// constraint as ports/stm32f4/GPIORegisters.swift: Sources/smk/
// KeyMatrix.swift treats gpio.outSet/outClear/input as one flat 32-bit bank
// (bit == GPIO number), which maps naturally onto one SAMD21 PORT group.
// Group A carries every matrix pin this port uses (the XIAO M0 breaks out
// nine PA pins; its two PB pins, D6/PB08 and D7/PB09, are simply not used).
//
// Register offsets verified against the vendored Microchip DFP
// (hw/mcu/microchip/samd21/include/component/port.h, fetched via TinyUSB's
// tools/get_deps.py):
//   PORT group A base: 0x4100_4400
//     0x08  DIRSET  (write-only: set direction to output)
//     0x10  OUT     (read: current output state)
//     0x14  OUTCLR  (write-only: drive low)
//     0x18  OUTSET  (write-only: drive high)
//     0x20  IN      (read: current input level, bit == pin number)
//
// Accesses go through swift-mmio (third_party/swift-mmio, compiled flat
// into this target — see cmake/SwiftMMIO.cmake), so every read/write is a
// real volatile load/store. The previous `.pointee` version was not: LLVM
// was free to hoist, merge or delete those accesses.

@RegisterBlock
struct GPIOPort {
    @RegisterBlock(offset: 0x10) var out: Register<GPIOWord>
    @RegisterBlock(offset: 0x14) var outclr: Register<GPIOWord>
    @RegisterBlock(offset: 0x18) var outset: Register<GPIOWord>
    @RegisterBlock(offset: 0x20) var `in`: Register<GPIOWord>
}

// One whole 32-bit word: the matrix code works in raw pin bitmasks, so no
// per-pin bit fields are modelled.
@Register(bitWidth: 32)
struct GPIOWord {
    @ReadWrite(bits: 0..<32, as: UInt32.self) var value: VALUE
}

struct GPIORegisters {
    static let base: UInt = 0x4100_4400 // PORT group A

    let port: GPIOPort

    init(address: UInt) {
        self.port = GPIOPort(unsafeAddress: address)
    }

    // 0x18: OUTSET — writing a 1 drives the corresponding output high.
    var outSet: UInt32 {
        get { port.out.read().value } // 0x10: OUT, current state
        nonmutating set { port.outset.write { $0.value = newValue } }
    }

    // 0x14: OUTCLR — writing a 1 drives the corresponding output low.
    var outClear: UInt32 {
        get { port.out.read().value } // 0x10: OUT, current state
        nonmutating set { port.outclr.write { $0.value = newValue } }
    }

    // 0x20: IN — current input level of every group-A pin (bit == pin number).
    var input: UInt32 {
        get { port.in.read().value }
    }
}

// Instantiate the bank at PORT group A's base address.
let gpio = GPIORegisters(address: GPIORegisters.base)

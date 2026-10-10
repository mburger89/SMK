// STM32WB55 GPIO register access — GPIOB only. See this plan's Global
// Constraints: Sources/smk/KeyMatrix.swift treats gpio.outSet/outClear/input
// as one flat 32-bit bank (bit == GPIO number), which doesn't natively span
// STM32's multiple 16-pin-wide GPIO ports without changing shared code
// (not done in this pass). GPIOB is used for the whole matrix (rows AND
// columns) — same single-port constraint as the STM32F4 port.
//
// Register offsets verified against cmsis-device-wb's GPIO_TypeDef
// (Include/stm32wb55xx.h) during this plan's research — identical field
// layout to STM32F4's GPIO_TypeDef, only the peripheral base address
// differs (WB puts GPIO on AHB2, F4 on AHB1).
//
// GPIOB base address: 0x4800_0400 (AHB2PERIPH_BASE + 0x0400) — differs from
// F4's GPIOB base (0x4002_0400); confirmed via stm32wb55xx.h's
// `#define GPIOB_BASE (IOPORT_BASE + 0x00000400UL)`, where
// `IOPORT_BASE = AHB2PERIPH_BASE + 0` and
// `AHB2PERIPH_BASE = PERIPH_BASE + 0x08000000UL` (PERIPH_BASE = 0x4000_0000).
//   0x14  ODR   (read: current output state)
//   0x18  BSRR  (write-only: bits[15:0] atomic set, bits[31:16] atomic reset)
//   0x10  IDR   (read: current input level, bit == pin number 0-15)
//
// Accesses go through swift-mmio (third_party/swift-mmio, compiled flat
// into this target — see cmake/SwiftMMIO.cmake), so every read/write is a
// real volatile load/store. The previous `.pointee` version was not: LLVM
// was free to hoist, merge or delete those accesses (see CLAUDE.md's
// register-polling note).

//
// GPIOInit.swift (GPIOB) and UsbHid.swift (GPIOA) also use this block for
// pin configuration: 0x00 MODER, 0x0C PUPDR, 0x24 AFRH (same
// cmsis-device-wb GPIO_TypeDef).
@RegisterBlock
struct GPIOPort {
    @RegisterBlock(offset: 0x00) var moder: Register<GPIOWord>
    @RegisterBlock(offset: 0x0C) var pupdr: Register<GPIOWord>
    @RegisterBlock(offset: 0x10) var idr: Register<GPIOWord>
    @RegisterBlock(offset: 0x14) var odr: Register<GPIOWord>
    @RegisterBlock(offset: 0x18) var bsrr: Register<GPIOWord>
    @RegisterBlock(offset: 0x24) var afrh: Register<GPIOWord>
}

// One whole 32-bit word: the matrix code works in raw pin bitmasks, so no
// per-pin bit fields are modelled.
@Register(bitWidth: 32)
struct GPIOWord {
    @ReadWrite(bits: 0..<32, as: UInt32.self) var value: VALUE
}

struct GPIORegisters {
    static let base: UInt = 0x48000400 // GPIOB

    let port: GPIOPort

    init(address: UInt) {
        self.port = GPIOPort(unsafeAddress: address)
    }

    // 0x18 (low half): BSRR — writing a 1 atomically sets the corresponding output high.
    var outSet: UInt32 {
        get { port.odr.read().value } // 0x14: ODR, current state
        nonmutating set { port.bsrr.write { $0.value = newValue & 0x0000_FFFF } }
    }

    // 0x18 (high half): BSRR — writing a 1 (shifted to bits[31:16]) atomically drives the corresponding output low.
    var outClear: UInt32 {
        get { port.odr.read().value } // 0x14: ODR, current state
        nonmutating set { port.bsrr.write { $0.value = (newValue & 0x0000_FFFF) << 16 } }
    }

    // 0x10: IDR — current input level of every GPIOB pin (bit == pin number, 0-15).
    var input: UInt32 {
        get { port.idr.read().value }
    }
}

// Instantiate the bank at the STM32WB55's GPIOB base address.
let gpio = GPIORegisters(address: GPIORegisters.base)

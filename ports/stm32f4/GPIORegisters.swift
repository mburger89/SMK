// STM32F4 GPIO register access — GPIOB only. See this plan's Global
// Constraints: Sources/smk/KeyMatrix.swift treats gpio.outSet/outClear/input
// as one flat 32-bit bank (bit == GPIO number), which doesn't natively span
// STM32's multiple 16-pin-wide GPIO ports without changing shared code
// (not done in this pass). GPIOB is used for the whole matrix (rows AND
// columns) since GPIOA carries USB D-/D+ (PA11/PA12, see UsbHid.swift) and
// the Black Pill's onboard user button (PA0).
//
// Register offsets verified against cmsis-device-f4's GPIO_TypeDef
// (Include/stm32f411xe.h) during this plan's research.
//
// GPIOB base address: 0x4002_0400 (AHB1PERIPH_BASE + 0x0400)
//   0x14  ODR   (read: current output state)
//   0x18  BSRR  (write-only: bits[15:0] atomic set, bits[31:16] atomic reset)
//   0x10  IDR   (read: current input level, bit == pin number 0-15)
//
// Accesses go through swift-mmio (third_party/swift-mmio, compiled flat
// into this target — see cmake/SwiftMMIO.cmake), so every read/write is a
// real volatile load/store. The previous `.pointee` version was not: LLVM
// was free to hoist, merge or delete those accesses (see CLAUDE.md's
// register-polling note).

@RegisterBlock
struct GPIOPort {
    @RegisterBlock(offset: 0x10) var idr: Register<GPIOWord>
    @RegisterBlock(offset: 0x14) var odr: Register<GPIOWord>
    @RegisterBlock(offset: 0x18) var bsrr: Register<GPIOWord>
}

// One whole 32-bit word: the matrix code works in raw pin bitmasks, so no
// per-pin bit fields are modelled.
@Register(bitWidth: 32)
struct GPIOWord {
    @ReadWrite(bits: 0..<32, as: UInt32.self) var value: VALUE
}

struct GPIORegisters {
    static let base: UInt = 0x40020400 // GPIOB

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

// Instantiate the bank at the STM32F411's GPIOB base address.
let gpio = GPIORegisters(address: GPIORegisters.base)

// Matrix settle delay (see smkMatrixSettleMicros in KeyMatrix.swift). This
// port has no calibrated microsecond delay to call, so it spins on volatile
// reads of the GPIO input register (swift-mmio: each one is a real bus
// access LLVM cannot delete, unlike the empty loop this replaced).
//
// STM32F411: 96 MHz SYSCLK = HCLK, set by smk_clock_init() in
// ports/stm32f4/ClockInit.swift (HSE 25 MHz / PLLM 25 * PLLN 384 / PLLP 4).
private let smkSettleCpuMHz: UInt32 = 96

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

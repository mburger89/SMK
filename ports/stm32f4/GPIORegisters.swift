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
struct GPIORegisters {
    static let base: UInt32 = 0x40020400 // GPIOB

    let baseAddress: UnsafeMutablePointer<UInt32>

    init(address: UInt32) {
        self.baseAddress = UnsafeMutablePointer<UInt32>(bitPattern: UInt(address))!
    }

    // 0x18 (low half): BSRR — writing a 1 atomically sets the corresponding output high.
    var outSet: UInt32 {
        get { baseAddress.advanced(by: 5).pointee } // 0x14: ODR, current state
        nonmutating set { baseAddress.advanced(by: 6).pointee = newValue & 0x0000_FFFF }
    }

    // 0x18 (high half): BSRR — writing a 1 (shifted to bits[31:16]) atomically drives the corresponding output low.
    var outClear: UInt32 {
        get { baseAddress.advanced(by: 5).pointee } // 0x14: ODR, current state
        nonmutating set { baseAddress.advanced(by: 6).pointee = (newValue & 0x0000_FFFF) << 16 }
    }

    // 0x10: IDR — current input level of every GPIOB pin (bit == pin number, 0-15).
    var input: UInt32 {
        get { baseAddress.advanced(by: 4).pointee }
    }
}

// Instantiate the bank at the STM32F411's GPIOB base address.
let gpio = GPIORegisters(address: GPIORegisters.base)

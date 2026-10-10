// STM32F4 matrix pin configuration (GPIOB only — see GPIORegisters.swift's
// header comment on the single-port constraint). Plain Swift: MODER/PUPDR
// are raw registers, no vendor driver call to wrap, same style
// ports/nrf52840/GPIOInit.swift already establishes for that port's PIN_CNF.
//
// Register bit layout verified against cmsis-device-f4's GPIO_TypeDef
// (Include/stm32f411xe.h) during this plan's research:
//   0x00 MODER  (2 bits per pin)
//   0x0C PUPDR  (2 bits per pin)
//   0x24 AFRH   (4 bits per pin, pins 8-15 — used by UsbHid.swift on GPIOA)
//
// All accesses go through swift-mmio (volatile). GPIOConfigPort is the one
// definition for this target: UsbHid.swift uses it for GPIOA too.

@RegisterBlock
struct GPIOConfigPort {
    @RegisterBlock(offset: 0x00) var moder: Register<GPIOWord>
    @RegisterBlock(offset: 0x0C) var pupdr: Register<GPIOWord>
    @RegisterBlock(offset: 0x24) var afrh: Register<GPIOWord>
}

private let gpiobConfig = GPIOConfigPort(unsafeAddress: GPIORegisters.base)

private let moderInput: UInt32 = 0b00
private let moderOutput: UInt32 = 0b01
private let pupdrNone: UInt32 = 0b00
private let pupdrUp: UInt32 = 0b01
private let pupdrDown: UInt32 = 0b10

// Read-modify-write of one pin's 2-bit field (one 32-bit load + one 32-bit
// store, same as the old `.pointee` version).
private func setTwoBitField(_ register: Register<GPIOWord>, pin: Int32, value: UInt32) {
    let shift = UInt32(pin) * 2
    let mask: UInt32 = 0b11 << shift
    register.modify { $0.value = ($0.value & ~mask) | (value << shift) }
}

// Two wiring conventions — see the matching comment in Sources/smk/KeyMatrix.swift.
// All pins here are GPIOB (0-15) — see this plan's Global Constraints.
func init_keyboard_pins(_ rows: UnsafePointer<Int32>, _ rowCount: Int32, _ cols: UnsafePointer<Int32>, _ colCount: Int32, _ colsAreDriven: Int32) {
    // RCC_AHB1ENR.GPIOBEN must be set before touching any GPIOB register.
    rcc.ahb1enr.modify { $0.gpioben = true }

    if colsAreDriven != 0 {
        // Rows: inputs with pull-downs (sense lines)
        for i in 0..<Int(rowCount) {
            setTwoBitField(gpiobConfig.moder, pin: rows[i], value: moderInput)
            setTwoBitField(gpiobConfig.pupdr, pin: rows[i], value: pupdrDown)
        }
        // Columns: push-pull outputs, idle LOW (strobe lines)
        for i in 0..<Int(colCount) {
            let pin = cols[i]
            setTwoBitField(gpiobConfig.moder, pin: pin, value: moderOutput)
            setTwoBitField(gpiobConfig.pupdr, pin: pin, value: pupdrNone)
            gpio.outClear = UInt32(1 << pin)
        }
    } else {
        // Rows: push-pull outputs, idle HIGH (strobe lines)
        for i in 0..<Int(rowCount) {
            let pin = rows[i]
            setTwoBitField(gpiobConfig.moder, pin: pin, value: moderOutput)
            setTwoBitField(gpiobConfig.pupdr, pin: pin, value: pupdrNone)
            gpio.outSet = UInt32(1 << pin)
        }
        // Columns: inputs with pull-ups (sense lines) — key press pulls to GND
        for i in 0..<Int(colCount) {
            setTwoBitField(gpiobConfig.moder, pin: cols[i], value: moderInput)
            setTwoBitField(gpiobConfig.pupdr, pin: cols[i], value: pupdrUp)
        }
    }
}

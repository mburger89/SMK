// STM32F4 matrix pin configuration (GPIOB only — see GPIORegisters.swift's
// header comment on the single-port constraint). Plain Swift: MODER/PUPDR
// are raw registers, no vendor driver call to wrap, same style
// ports/nrf52840/GPIOInit.swift already establishes for that port's PIN_CNF.
//
// Register bit layout verified against cmsis-device-f4's GPIO_TypeDef
// (Include/stm32f411xe.h) during this plan's research.
private let moderBase = UnsafeMutablePointer<UInt32>(bitPattern: UInt(GPIORegisters.base + 0x00))!
private let pupdrBase = UnsafeMutablePointer<UInt32>(bitPattern: UInt(GPIORegisters.base + 0x0C))!

private let moderInput: UInt32 = 0b00
private let moderOutput: UInt32 = 0b01
private let pupdrNone: UInt32 = 0b00
private let pupdrUp: UInt32 = 0b01
private let pupdrDown: UInt32 = 0b10

private func setTwoBitField(_ register: UnsafeMutablePointer<UInt32>, pin: Int32, value: UInt32) {
    let shift = UInt32(pin) * 2
    let mask: UInt32 = 0b11 << shift
    register.pointee = (register.pointee & ~mask) | (value << shift)
}

// RCC_AHB1ENR (RCC base 0x4002_3800 + 0x30) bit 1 = GPIOBEN. Must be
// enabled before touching any GPIOB register — verified against
// cmsis-device-f4's RCC_TypeDef during this plan's research.
private let rccAhb1Enr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0x40023800 + 0x30))!
private let rccAhb1EnrGpiobEn: UInt32 = 1 << 1

// Two wiring conventions — see the matching comment in Sources/smk/KeyMatrix.swift.
// All pins here are GPIOB (0-15) — see this plan's Global Constraints.
func init_keyboard_pins(_ rows: UnsafePointer<Int32>, _ rowCount: Int32, _ cols: UnsafePointer<Int32>, _ colCount: Int32, _ colsAreDriven: Int32) {
    rccAhb1Enr.pointee |= rccAhb1EnrGpiobEn

    if colsAreDriven != 0 {
        // Rows: inputs with pull-downs (sense lines)
        for i in 0..<Int(rowCount) {
            setTwoBitField(moderBase, pin: rows[i], value: moderInput)
            setTwoBitField(pupdrBase, pin: rows[i], value: pupdrDown)
        }
        // Columns: push-pull outputs, idle LOW (strobe lines)
        for i in 0..<Int(colCount) {
            let pin = cols[i]
            setTwoBitField(moderBase, pin: pin, value: moderOutput)
            setTwoBitField(pupdrBase, pin: pin, value: pupdrNone)
            gpio.outClear = UInt32(1 << pin)
        }
    } else {
        // Rows: push-pull outputs, idle HIGH (strobe lines)
        for i in 0..<Int(rowCount) {
            let pin = rows[i]
            setTwoBitField(moderBase, pin: pin, value: moderOutput)
            setTwoBitField(pupdrBase, pin: pin, value: pupdrNone)
            gpio.outSet = UInt32(1 << pin)
        }
        // Columns: inputs with pull-ups (sense lines) — key press pulls to GND
        for i in 0..<Int(colCount) {
            setTwoBitField(moderBase, pin: cols[i], value: moderInput)
            setTwoBitField(pupdrBase, pin: cols[i], value: pupdrUp)
        }
    }
}

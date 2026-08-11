// STM32WB55 matrix pin configuration (GPIOB only — see GPIORegisters.swift's
// header comment on the single-port constraint). Plain Swift: MODER/PUPDR
// are raw registers, no vendor driver call to wrap, same style
// ports/stm32f4/GPIOInit.swift (and ports/nrf52840/GPIOInit.swift before it)
// already establish.
//
// Register bit layout verified against cmsis-device-wb's GPIO_TypeDef
// (Include/stm32wb55xx.h) during this plan's research — identical to
// STM32F4's GPIO_TypeDef field layout.
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

// RCC_AHB2ENR (RCC base 0x5800_0000 + 0x4C) bit 1 = GPIOBEN. Must be
// enabled before touching any GPIOB register. Differs from F4's
// RCC_AHB1ENR — WB puts GPIO clock-enable on AHB2, not AHB1 — but the same
// bit position (bit 1) for GPIOBEN, confirmed consistent across the family.
// Verified against cmsis-device-wb's RCC_TypeDef during this plan's
// research: `AHB2ENR` sits at offset 0x4C within RCC_TypeDef, and
// `RCC_AHB2ENR_GPIOBEN_Pos` is bit 1.
private let rccAhb2Enr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(0x58000000 + 0x4C))!
private let rccAhb2EnrGpiobEn: UInt32 = 1 << 1

// Two wiring conventions — see the matching comment in Sources/smk/KeyMatrix.swift.
// All pins here are GPIOB (0-15) — see this plan's Global Constraints.
func init_keyboard_pins(_ rows: UnsafePointer<Int32>, _ rowCount: Int32, _ cols: UnsafePointer<Int32>, _ colCount: Int32, _ colsAreDriven: Int32) {
    rccAhb2Enr.pointee |= rccAhb2EnrGpiobEn

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

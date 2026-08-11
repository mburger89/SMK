// nRF52840 matrix pin configuration — same role as
// Sources/smk/GPIOInit.swift (ESP32-C6) and
// ports/rp2040/GPIOInit.swift (RP2040, also plain Swift now). Plain Swift
// here: PIN_CNF is a raw register, so there's no vendor driver call to
// wrap via @_extern(c) the way ESP32-C6's version needs — just direct
// UnsafeMutablePointer writes, same style GPIORegisters.swift already
// uses for the scan loop itself.
//
// Register offsets verified against Nordic's nRF52840 Product
// Specification during this port's feasibility spike:
// docs/superpowers/specs/2026-08-09-nrf52840-support-design.md.
private let pinCnfBase: UInt32 = GPIORegisters.base + 0x700

private func pinCnfAddress(_ pin: Int32) -> UnsafeMutablePointer<UInt32> {
    UnsafeMutablePointer<UInt32>(bitPattern: UInt(pinCnfBase + UInt32(pin) * 4))!
}

private let pinCnfDirInput: UInt32 = 0 << 0
private let pinCnfDirOutput: UInt32 = 1 << 0
private let pinCnfInputConnect: UInt32 = 0 << 1
private let pinCnfInputDisconnect: UInt32 = 1 << 1
private let pinCnfPullDisabled: UInt32 = 0 << 2
private let pinCnfPullDown: UInt32 = 1 << 2
private let pinCnfPullUp: UInt32 = 3 << 2
private let pinCnfDriveS0S1: UInt32 = 0 << 8

// Two wiring conventions — see the matching comment in
// Sources/smk/KeyMatrix.swift. Only P0 (GPIO 0-31) is wired here — see
// GPIORegisters.swift's own note on why P1 is unused for this board.
func init_keyboard_pins(_ rows: UnsafePointer<Int32>, _ rowCount: Int32, _ cols: UnsafePointer<Int32>, _ colCount: Int32, _ colsAreDriven: Int32) {
    if colsAreDriven != 0 {
        // Rows: inputs with pull-downs (sense lines)
        for i in 0..<Int(rowCount) {
            pinCnfAddress(rows[i]).pointee = pinCnfDirInput | pinCnfInputConnect | pinCnfPullDown | pinCnfDriveS0S1
        }
        // Columns: push-pull outputs, idle LOW (strobe lines)
        for i in 0..<Int(colCount) {
            let pin = cols[i]
            pinCnfAddress(pin).pointee = pinCnfDirOutput | pinCnfInputDisconnect | pinCnfPullDisabled | pinCnfDriveS0S1
            gpio.outClear = UInt32(1 << pin)
        }
    } else {
        // Rows: push-pull outputs, idle HIGH (strobe lines)
        for i in 0..<Int(rowCount) {
            let pin = rows[i]
            pinCnfAddress(pin).pointee = pinCnfDirOutput | pinCnfInputDisconnect | pinCnfPullDisabled | pinCnfDriveS0S1
            gpio.outSet = UInt32(1 << pin)
        }
        // Columns: inputs with pull-ups (sense lines) — key press pulls to GND
        for i in 0..<Int(colCount) {
            pinCnfAddress(cols[i]).pointee = pinCnfDirInput | pinCnfInputConnect | pinCnfPullUp | pinCnfDriveS0S1
        }
    }
}

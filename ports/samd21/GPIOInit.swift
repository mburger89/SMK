// SAMD21 matrix pin configuration — same-module Swift, same role as
// ports/stm32f4/GPIOInit.swift (KeyMatrix.swift's @_extern declaration for
// init_keyboard_pins compiles out on this target; see main branch guards).
//
// Direct PORT register pokes rather than any vendor HAL: SAMD21 pin config
// is simple enough that the ASF hal/hpl layer would be pure overhead.
// Register/bit facts verified against the vendored DFP's component/port.h:
//   DIR    0x00 / DIRCLR 0x04 / DIRSET 0x08  (32-bit, bit == pin)
//   OUTCLR 0x14 / OUTSET 0x18               (32-bit, bit == pin)
//   PINCFGn 0x40 + n                         (8-bit per pin):
//     bit 0 PMUXEN, bit 1 INEN, bit 2 PULLEN
// Pull direction is selected by the OUT bit while PULLEN is set:
// OUT=0 -> pull-down, OUT=1 -> pull-up (SAMD21 datasheet, PORT chapter).

private let portABase: UInt32 = 0x4100_4400
private let portADirClr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(portABase + 0x04))!
private let portADirSet = UnsafeMutablePointer<UInt32>(bitPattern: UInt(portABase + 0x08))!
private let portAOutClr = UnsafeMutablePointer<UInt32>(bitPattern: UInt(portABase + 0x14))!
private let portAOutSet = UnsafeMutablePointer<UInt32>(bitPattern: UInt(portABase + 0x18))!
private let portAPinCfg = UnsafeMutablePointer<UInt8>(bitPattern: UInt(portABase + 0x40))!

private let pinCfgInputEnable: UInt8 = 1 << 1 // INEN
private let pinCfgPullEnable: UInt8 = 1 << 2  // PULLEN

private func configureOutput(_ pin: Int32, level: UInt32) {
    portAPinCfg.advanced(by: Int(pin)).pointee = 0 // plain GPIO, no mux/input/pull
    if level != 0 {
        portAOutSet.pointee = 1 << UInt32(pin)
    } else {
        portAOutClr.pointee = 1 << UInt32(pin)
    }
    portADirSet.pointee = 1 << UInt32(pin)
}

private func configureInput(_ pin: Int32, pullUp: Bool) {
    portADirClr.pointee = 1 << UInt32(pin)
    portAPinCfg.advanced(by: Int(pin)).pointee = pinCfgInputEnable | pinCfgPullEnable
    if pullUp {
        portAOutSet.pointee = 1 << UInt32(pin) // OUT=1 + PULLEN -> pull-up
    } else {
        portAOutClr.pointee = 1 << UInt32(pin) // OUT=0 + PULLEN -> pull-down
    }
}

// Two wiring conventions — see the matching comment in KeyMatrix.swift and
// ports/stm32f4/GPIOInit.swift (identical contract).
func init_keyboard_pins(_ rows: UnsafePointer<Int32>, _ rowCount: Int32, _ cols: UnsafePointer<Int32>, _ colCount: Int32, _ colsAreDriven: Int32) {
    if colsAreDriven != 0 {
        // Rows: inputs with pull-downs (sense); columns: outputs idle LOW (strobe).
        for i in 0..<Int(rowCount) { configureInput(rows[i], pullUp: false) }
        for i in 0..<Int(colCount) { configureOutput(cols[i], level: 0) }
    } else {
        // Rows: outputs idle HIGH (strobe); columns: inputs with pull-ups (sense).
        for i in 0..<Int(rowCount) { configureOutput(rows[i], level: 1) }
        for i in 0..<Int(colCount) { configureInput(cols[i], pullUp: true) }
    }
}

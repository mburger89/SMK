// nRF52840 GPIO (P0) raw register access — same outSet/outClear/input API
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
//   0x504  OUT      (read/write)        -> word index 321
//   0x508  OUTSET   (atomic set bits)   -> word index 322
//   0x50C  OUTCLR   (atomic clear bits) -> word index 323
//   0x510  IN       (read)              -> word index 324

struct GPIORegisters {
    static let base: UInt32 = 0x50000000

    let baseAddress: UnsafeMutablePointer<UInt32>

    init(address: UInt32) {
        self.baseAddress = UnsafeMutablePointer<UInt32>(bitPattern: UInt(address))!
    }

    // 0x508: OUTSET — writing a 1 sets the corresponding output high.
    var outSet: UInt32 {
        get { baseAddress.advanced(by: 322).pointee }
        nonmutating set { baseAddress.advanced(by: 322).pointee = newValue }
    }

    // 0x50C: OUTCLR — writing a 1 drives the corresponding output low.
    var outClear: UInt32 {
        get { baseAddress.advanced(by: 323).pointee }
        nonmutating set { baseAddress.advanced(by: 323).pointee = newValue }
    }

    // 0x510: IN — current input level of every P0 pin (bit == GPIO number).
    var input: UInt32 {
        get { baseAddress.advanced(by: 324).pointee }
    }
}

// Instantiate the bank at the nRF52840 P0 base address.
let gpio = GPIORegisters(address: GPIORegisters.base)

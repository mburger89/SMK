// RP2040 / RP2350 GPIO register access via the SIO (Single-cycle IO) block.
//
// This is the RP2040/RP2350 counterpart to the ESP32 `Sources/smk/GPIORegisters.swift`.
// It deliberately exposes the SAME `outSet` / `outClear` / `input` API (with
// bit position == GPIO number) so that the shared `KeyMatrix.scan()` compiles
// and runs unchanged across both platforms.
//
// The SIO GPIO register block (base address and offsets below) is identical
// between RP2040 and RP2350, so this one file covers both chips unchanged.
//
// SIO base address: 0xD000_0000
//   0x004  GPIO_IN       (read)              -> word index 1
//   0x010  GPIO_OUT      (read/write)        -> word index 4
//   0x014  GPIO_OUT_SET  (atomic set bits)   -> word index 5
//   0x018  GPIO_OUT_CLR  (atomic clear bits) -> word index 6
//
// NOTE: The SIO only drives/reads the pin *level*. Each pad must first be
// muxed to the SIO function and have its direction / pull-ups configured.
// That one-time setup is done in `platform/gpio_init.c` via the pico-sdk.

struct GPIORegisters {
    let baseAddress: UnsafeMutablePointer<UInt32>

    init(address: UInt32) {
        self.baseAddress = UnsafeMutablePointer<UInt32>(bitPattern: UInt(address))!
    }

    // 0x014: GPIO_OUT_SET — writing a 1 sets the corresponding output high.
    var outSet: UInt32 {
        get { baseAddress.advanced(by: 5).pointee }
        nonmutating set { baseAddress.advanced(by: 5).pointee = newValue }
    }

    // 0x018: GPIO_OUT_CLR — writing a 1 drives the corresponding output low.
    var outClear: UInt32 {
        get { baseAddress.advanced(by: 6).pointee }
        nonmutating set { baseAddress.advanced(by: 6).pointee = newValue }
    }

    // 0x004: GPIO_IN — current input level of every GPIO (bit == GPIO number).
    var input: UInt32 {
        get { baseAddress.advanced(by: 1).pointee }
    }
}

// Instantiate the bank at the RP2040 SIO base address.
let gpio = GPIORegisters(address: 0xD0000000)

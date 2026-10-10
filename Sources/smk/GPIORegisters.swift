// ESP32-C6 GPIO register access.
//
// GPIO base address: 0x6009_1000
//   0x04  GPIO_OUT_W1TS_REG (write 1 = set that output bit)
//   0x08  GPIO_OUT_W1TC_REG (write 1 = clear that output bit)
//   0x3C  GPIO_IN_REG       (read: current input level, bit == GPIO number)
//
// Accesses go through swift-mmio (third_party/swift-mmio, compiled flat
// into this target — see cmake/SwiftMMIO.cmake), so every read/write is a
// real volatile load/store. The previous `.pointee` version was not: LLVM
// was free to hoist, merge or delete those accesses (see CLAUDE.md's
// register-polling note).

@RegisterBlock
struct ESPGPIO {
    @RegisterBlock(offset: 0x04) var outW1TS: Register<GPIOWord>
    @RegisterBlock(offset: 0x08) var outW1TC: Register<GPIOWord>
    @RegisterBlock(offset: 0x3C) var input: Register<GPIOWord>
}

// One whole 32-bit word: the matrix code works in raw pin bitmasks, so no
// per-pin bit fields are modelled.
@Register(bitWidth: 32)
struct GPIOWord {
    @ReadWrite(bits: 0..<32, as: UInt32.self) var value: VALUE
}

struct GPIORegisters {
    static let base: UInt = 0x60091000

    let regs: ESPGPIO

    init(address: UInt) {
        self.regs = ESPGPIO(unsafeAddress: address)
    }

    // Offset 0x0004: GPIO_OUT_W1TS_REG (Set bits). The getter reads the same
    // register, exactly as the previous `.pointee` version did.
    var outSet: UInt32 {
        get { regs.outW1TS.read().value }
        nonmutating set { regs.outW1TS.write { $0.value = newValue } }
    }

    // Offset 0x0008: GPIO_OUT_W1TC_REG (Clear bits). Getter reads the same
    // register, as before.
    var outClear: UInt32 {
        get { regs.outW1TC.read().value }
        nonmutating set { regs.outW1TC.write { $0.value = newValue } }
    }

    // Offset 0x003C: GPIO_IN_REG (Read data)
    var input: UInt32 {
        get { regs.input.read().value }
    }
}

// Instantiate the bank at the correct memory address for ESP32-C6 GPIO
let gpio = GPIORegisters(address: GPIORegisters.base)

// Matrix settle delay (see smkMatrixSettleMicros in KeyMatrix.swift).
// esp_rom_delay_us is the ROM's calibrated busy-wait (an alias of
// ets_delay_us via esp32c6.rom.api.ld), counted off the CPU cycle counter, so
// it is accurate at whatever CPU frequency is configured. Bridging.h imports
// no header that declares it, hence the @_extern binding.
@_extern(c, "esp_rom_delay_us")
func esp_rom_delay_us(_ us: UInt32)

// @inline(never) keeps this a distinct symbol that tools/build_all.sh
// --check-polls can find (scan() must call it; it must call the ROM delay).
@inline(never)
func smkSettleDelay() {
    esp_rom_delay_us(smkMatrixSettleMicros)
}

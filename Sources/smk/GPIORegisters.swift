import MMIO

@RegisterBank
struct GPIORegisters {
    // Offset 0x0004: GPIO_OUT_W1TS_REG (Set bits)
    @Register(bitWidth: 32)
    var outSet: OutSet
    
    // Offset 0x0008: GPIO_OUT_W1TC_REG (Clear bits)
    @Register(bitWidth: 32)
    var outClear: OutClear
    
    // Offset 0x003C: GPIO_IN_REG (Read data)
    @Register(bitWidth: 32)
    var input: Input
}

// Instantiate the bank at the correct memory address
let gpio = GPIORegisters(unsafeAddress: 0x60091000)

struct GPIORegisters {
    let baseAddress: UnsafeMutablePointer<UInt32>

    init(address: UInt32) {
        self.baseAddress = UnsafeMutablePointer<UInt32>(bitPattern: UInt(address))!
    }

    // Offset 0x0004: GPIO_OUT_W1TS_REG (Set bits)
    var outSet: UInt32 {
        get { baseAddress.advanced(by: 1).pointee }
        nonmutating set { baseAddress.advanced(by: 1).pointee = newValue }
    }
    
    // Offset 0x0008: GPIO_OUT_W1TC_REG (Clear bits)
    var outClear: UInt32 {
        get { baseAddress.advanced(by: 2).pointee }
        nonmutating set { baseAddress.advanced(by: 2).pointee = newValue }
    }
    
    // Offset 0x003C: GPIO_IN_REG (Read data)
    var input: UInt32 {
        get { baseAddress.advanced(by: 15).pointee }
    }
}

// Instantiate the bank at the correct memory address for ESP32-C6 GPIO
let gpio = GPIORegisters(address: 0x60091000)

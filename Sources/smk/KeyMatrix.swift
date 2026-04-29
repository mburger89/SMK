enum Modifier: UInt8 {
    case leftCtrl
    case leftShift
    case leftAlt
    case leftGUI
    case rightCtrl
    case rightShift
    case rightAlt
    case rightGUI

    var rawValue: UInt8 {
        switch self {
        case .leftCtrl:   return 0b00000001
        case .leftShift:  return 0b00000010
        case .leftAlt:    return 0b00000100
        case .leftGUI:    return 0b00001000
        case .rightCtrl:  return 0b00010000
        case .rightShift: return 0b00100000
        case .rightAlt:   return 0b01000000
        case .rightGUI:   return 0b10000000
        }
    }
}

@_extern(c, "init_keyboard_pins")
func init_keyboard_pins(_ rows: UnsafePointer<Int32>, _ rowCount: Int32, _ cols: UnsafePointer<Int32>, _ colCount: Int32)

struct KeyMatrix {
    let rowPins: [Int32]
    let colPins: [Int32]
    let totalKeys: Int

    init(rowPins: [Int32], colPins: [Int32]) {
        self.rowPins = rowPins
        self.colPins = colPins
        self.totalKeys = rowPins.count * colPins.count

        rowPins.withUnsafeBufferPointer { rowPtr in
            colPins.withUnsafeBufferPointer { colPtr in
                if let rBase = rowPtr.baseAddress, let cBase = colPtr.baseAddress {
                    init_keyboard_pins(rBase, Int32(rowPins.count), cBase, Int32(colPins.count))
                }
            }
        }
    }

    func scan() -> [Bool] {
        var state = [Bool](repeating: false, count: totalKeys)
        let colCount = colPins.count

        for (rIdx, rPin) in rowPins.enumerated() {
            // Pull row LOW to activate it
            gpio.outClear = UInt32(1 << rPin)
            
            // Brief pause for electrical stabilization
            for _ in 0...50 { }

            let inputState = gpio.input
            
            for (cIdx, cPin) in colPins.enumerated() {
                // If the column bit is 0, the switch is closed (pressed)
                if (inputState & (1 << UInt32(cPin))) == 0 {
                    state[rIdx * colCount + cIdx] = true
                }
            }

            // Return row HIGH (inactive)
            gpio.outSet = UInt32(1 << rPin)
        }
        return state
    }
}

struct DebouncedMatrix {
    private let totalKeys: Int
    private let debounceThreshold = 5

    private var counters: [Int]
    private var stableState: [Bool]

    init(totalKeys: Int) {
        self.totalKeys = totalKeys
        self.counters = [Int](repeating: 0, count: totalKeys)
        self.stableState = [Bool](repeating: false, count: totalKeys)
    }

    mutating func update(rawScan: [Bool]) -> [Bool] {
        for i in 0..<totalKeys {
            if i >= rawScan.count { break }
            if rawScan[i] != stableState[i] {
                counters[i] += 1
                if counters[i] >= debounceThreshold {
                    stableState[i] = rawScan[i]
                    counters[i] = 0
                }
            } else {
                counters[i] = 0
            }
        }
        return stableState
    }
}

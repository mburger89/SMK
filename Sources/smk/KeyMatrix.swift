struct MatrixConfig {
    // Example GPIO assignments (adjust based on your PCB/wiring)
    static let rowPins: [Int32] = [0, 1, 2, 3, 4]
    static let colPins: [Int32] = [5, 6, 7, 9, 10, 11, 18, 19, 20, 21, 22, 23]
}
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
    init() {
        init_keyboard_pins(MatrixConfig.rowPins, 5, MatrixConfig.colPins, 12)
    }

    func scan() -> [Bool] {
        // Flat array of 60 keys (true = pressed)
        var state = [Bool](repeating: false, count: 60)

        for (rIdx, rPin) in MatrixConfig.rowPins.enumerated() {
            // Pull row LOW to activate it
            gpio.outClear.write { $0.raw = UInt32(1 << rPin) }
            
            // Brief pause for electrical stabilization
            for _ in 0...50 { }

            let inputState = gpio.input.read().raw
            
            for (cIdx, cPin) in MatrixConfig.colPins.enumerated() {
                // If the column bit is 0, the switch is closed (pressed)
                if (inputState & (1 << cPin)) == 0 {
                    state[rIdx * 12 + cIdx] = true
                }
            }

            // Return row HIGH (inactive)
            gpio.outSet.write { $0.raw = UInt32(1 << rPin) }
        }
        return state
    }
}

struct DebouncedMatrix {
    private let rowCount = 5
    private let colCount = 12
    private let debounceThreshold = 5 // Number of scans to confirm state

    // Tracks the current count for each key
    private var counters: [Int]
    // Tracks the "stable" state reported to the layer engine
    private var stableState: [Bool]

    init() {
        self.counters = [Int](repeating: 0, count: 60)
        self.stableState = [Bool](repeating: false, count: 60)
    }

    // Takes the raw "noisy" scan and returns the "clean" state
    mutating func update(rawScan: [Bool]) -> [Bool] {
        for i in 0..<60 {
            if rawScan[i] != stableState[i] {
                // Signal is different from our stable state, increment counter
                counters[i] += 1

                if counters[i] >= debounceThreshold {
                    // Signal has been stable long enough, flip the state
                    stableState[i] = rawScan[i]
                    counters[i] = 0
                }
            } else {
                // Signal matches stable state, reset counter
                counters[i] = 0
            }
        }
        return stableState
    }
}

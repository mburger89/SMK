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

// ESP32-C6 provides this as a plain Swift function (GPIOInit.swift, part
// of this same module — see main/CMakeLists.txt's swift_srcs); RP2040
// still provides it as a C function (ports/rp2040/platform/gpio_init.c),
// so only that build declares it here as an extern symbol to link against.
#if !SMK_TARGET_ESP32C6
@_extern(c, "init_keyboard_pins")
func init_keyboard_pins(_ rows: UnsafePointer<Int32>, _ rowCount: Int32, _ cols: UnsafePointer<Int32>, _ colCount: Int32, _ colsAreDriven: Int32)
#endif

// Two wiring conventions coexist across targets/boards:
//   - colsAreDriven == false (legacy/RP2040): rows are push-pull outputs
//     (idle HIGH, strobed LOW one at a time); columns are inputs with
//     pull-ups (idle HIGH, read LOW when a key on the active row is pressed).
//   - colsAreDriven == true (ESP32-C6 smk_kbd board): the opposite —
//     columns are push-pull outputs (idle LOW, strobed HIGH one at a time);
//     rows are inputs with pull-downs (idle LOW, read HIGH when a key on the
//     active column is pressed). This matches that board's COL2ROW diode
//     orientation (anode at the switch/column side, cathode at the row
//     side) — current only flows column -> row, so the driven line must be
//     pulled toward the column, not the row.
// Which convention applies is set per-board in the JSON config
// (matrix.colsAreDriven) and passed straight through to init_keyboard_pins
// so the C-side pin configuration matches what scan() assumes.
struct KeyMatrix {
    let rowPins: [Int32]
    let colPins: [Int32]
    let totalKeys: Int
    let colsAreDriven: Bool

    init(rowPins: [Int32], colPins: [Int32], colsAreDriven: Bool = false) {
        self.rowPins = rowPins
        self.colPins = colPins
        self.totalKeys = rowPins.count * colPins.count
        self.colsAreDriven = colsAreDriven

        rowPins.withUnsafeBufferPointer { rowPtr in
            colPins.withUnsafeBufferPointer { colPtr in
                if let rBase = rowPtr.baseAddress, let cBase = colPtr.baseAddress {
                    init_keyboard_pins(rBase, Int32(rowPins.count), cBase, Int32(colPins.count), colsAreDriven ? 1 : 0)
                }
            }
        }
    }

    func scan() -> [Bool] {
        var state = [Bool](repeating: false, count: totalKeys)
        let colCount = colPins.count

        if colsAreDriven {
            for (cIdx, cPin) in colPins.enumerated() {
                // Drive the column HIGH to activate it
                gpio.outSet = UInt32(1 << cPin)

                // Brief pause for electrical stabilization
                for _ in 0...50 { }

                let inputState = gpio.input

                for (rIdx, rPin) in rowPins.enumerated() {
                    // Row reads HIGH (pull-down default) when pressed on the active column
                    if (inputState & (1 << UInt32(rPin))) != 0 {
                        state[rIdx * colCount + cIdx] = true
                    }
                }

                // Return column LOW (inactive)
                gpio.outClear = UInt32(1 << cPin)
            }
        } else {
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

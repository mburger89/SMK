// ESP32-C6, RP2040, nRF52840, STM32F4, and STM32WB provide this as a plain
// Swift function (GPIOInit.swift, part of this same module — see
// main/CMakeLists.txt's, ports/rp2040/CMakeLists.txt's,
// ports/nrf52840/CMakeLists.txt's, ports/stm32f4/CMakeLists.txt's, and
// ports/stm32wb/CMakeLists.txt's swift_srcs).
#if !SMK_TARGET_ESP32C6 && !SMK_TARGET_RP2040 && !SMK_TARGET_NRF52840 && !SMK_TARGET_STM32F4 && !SMK_TARGET_STM32WB
@_extern(c, "init_keyboard_pins")
func init_keyboard_pins(_ rows: UnsafePointer<Int32>, _ rowCount: Int32, _ cols: UnsafePointer<Int32>, _ colCount: Int32, _ colsAreDriven: Int32)
#endif

// smk_cpu_nop() — opaque no-op called from inside scan()'s settling-delay
// loops below (see that comment for why). STM32F4/STM32WB already declare
// this via @_extern in their own ClockInit.swift (same module, same
// target, called there from register-polling loops for the identical
// reason) — declaring it again here would be a same-module redeclaration
// conflict, so only the three targets that don't already have it declare
// it here. Implementations: Sources/components/cpu_intrinsics.c
// (ESP32-C6), ports/rp2040/platform/cortex_m_intrinsics.c,
// ports/nrf52840/platform/cortex_m_intrinsics.c.
#if SMK_TARGET_ESP32C6 || SMK_TARGET_RP2040 || SMK_TARGET_NRF52840
@_extern(c, "smk_cpu_nop")
func smk_cpu_nop()
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

                // Brief pause for electrical stabilization. smk_cpu_nop()
                // is not optional here — see its own declaration comment
                // above: an empty-bodied loop like this has zero side
                // effects Swift can see, so LLVM deletes it outright under
                // the forward-progress rule at this project's -Osize
                // build flags, turning this into a zero-length "delay"
                // (found by compiling this exact pattern and inspecting
                // the emitted IR — the strobe and the read below ended up
                // adjacent with no loop between them at all).
                for _ in 0...50 { smk_cpu_nop() }

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

                // Brief pause for electrical stabilization — see the
                // colsAreDriven branch above for why smk_cpu_nop() is
                // required here, not optional.
                for _ in 0...50 { smk_cpu_nop() }

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


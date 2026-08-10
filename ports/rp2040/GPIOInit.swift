// RP2040 keyboard matrix pin setup — Swift port of the former
// ports/rp2040/platform/gpio_init.c. Only compiled into the RP2040 build
// (ports/rp2040/CMakeLists.txt), so this is a plain module-internal Swift
// function, not @_extern/@_cdecl — nothing outside this Swift module calls
// it. Matches Sources/smk/GPIOInit.swift's precedent for ESP32-C6.
//
// Two wiring conventions are supported (see the matching comment in
// Sources/smk/KeyMatrix.swift) — which one applies is passed in from the
// shared JSON config via colsAreDriven:
//
//   colsAreDriven == 0 (this board's default): rows are push-pull outputs,
//   driven HIGH (inactive) at rest; scan() pulls a row LOW to select it.
//   Columns are inputs with pull-ups (active-low when a key bridges
//   row->col).
//
//   colsAreDriven != 0: the opposite — columns are driven, rows are sensed
//   with pull-downs. Not used by the current RP2040 config, but supported
//   for parity with the ESP32-C6/smk_kbd_rp2040 boards' COL2ROW wiring.

@_extern(c, "gpio_init")
func gpio_init(_ gpioNum: UInt32)

@_extern(c, "smk_gpio_set_dir")
func smk_gpio_set_dir(_ gpioNum: UInt32, _ out: Bool)

@_extern(c, "smk_gpio_pull_up")
func smk_gpio_pull_up(_ gpioNum: UInt32)

@_extern(c, "smk_gpio_pull_down")
func smk_gpio_pull_down(_ gpioNum: UInt32)

@_extern(c, "smk_gpio_put")
func smk_gpio_put(_ gpioNum: UInt32, _ value: Bool)

func init_keyboard_pins(_ rows: UnsafePointer<Int32>, _ rowCount: Int32, _ cols: UnsafePointer<Int32>, _ colCount: Int32, _ colsAreDriven: Int32) {
    if colsAreDriven != 0 {
        // Rows: inputs with pull-downs (sense lines)
        for i in 0..<Int(rowCount) {
            let pin = UInt32(rows[i])
            gpio_init(pin)
            smk_gpio_set_dir(pin, false)
            smk_gpio_pull_down(pin)
        }
        // Columns: push-pull outputs, idle LOW (strobe lines)
        for i in 0..<Int(colCount) {
            let pin = UInt32(cols[i])
            gpio_init(pin)
            smk_gpio_set_dir(pin, true)
            smk_gpio_put(pin, false)
        }
    } else {
        // Rows: outputs, default HIGH (inactive). scan() pulls a row LOW to select it.
        for i in 0..<Int(rowCount) {
            let pin = UInt32(rows[i])
            gpio_init(pin)
            smk_gpio_set_dir(pin, true)
            smk_gpio_put(pin, true)
        }
        // Columns: inputs with pull-ups (active-low when a key bridges row->col).
        for i in 0..<Int(colCount) {
            let pin = UInt32(cols[i])
            gpio_init(pin)
            smk_gpio_set_dir(pin, false)
            smk_gpio_pull_up(pin)
        }
    }
}

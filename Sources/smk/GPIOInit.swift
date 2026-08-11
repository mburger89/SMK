// ESP32-C6 matrix pin configuration — Swift port of the former
// Sources/components/gpio_init.c. Only compiled into the ESP32-C6 build
// (main/CMakeLists.txt), so this is a plain module-internal Swift
// function, not `@_extern`/`@_cdecl` — nothing outside this Swift module
// calls it. RP2040 and nRF52840 each have their own same-module Swift
// definition too now (ports/rp2040/GPIOInit.swift,
// ports/nrf52840/GPIOInit.swift). KeyMatrix.swift's `@_extern(c,
// "init_keyboard_pins")` declaration is gated to compile out on all three
// targets (`#if !SMK_TARGET_ESP32C6 && !SMK_TARGET_RP2040 &&
// !SMK_TARGET_NRF52840`, see main/CMakeLists.txt) — a real C declaration
// would conflict with each target's same-signature Swift definition,
// which is why it's conditional rather than KeyMatrix.swift's call site
// changing.
//
// Calls straight into the ESP-IDF gpio driver (esp_driver_gpio component,
// already a REQUIRES in main/CMakeLists.txt) rather than reimplementing
// pull-up/down + IOMUX configuration at the register level — that's
// significantly more involved than the simple output-register pokes
// KeyMatrix.swift's scan() does itself.
//
// Embedded Swift doesn't import driver/gpio.h here (matching this
// project's existing extern-only C interop style throughout), so
// gpio_num_t/gpio_mode_t are passed as their raw Int32 values:
// gpio_num_t's raw value is just the pin number, and GPIO_MODE_INPUT/
// GPIO_MODE_OUTPUT below mirror hal/gpio_types.h's GPIO_MODE_DEF_INPUT
// (BIT0) / GPIO_MODE_DEF_OUTPUT (BIT1) bitmasks — stable, public ESP-IDF
// API values.

@_extern(c, "gpio_reset_pin")
func gpio_reset_pin(_ gpioNum: Int32) -> Int32

@_extern(c, "gpio_set_direction")
func gpio_set_direction(_ gpioNum: Int32, _ mode: Int32) -> Int32

@_extern(c, "gpio_pulldown_en")
func gpio_pulldown_en(_ gpioNum: Int32) -> Int32

@_extern(c, "gpio_pullup_dis")
func gpio_pullup_dis(_ gpioNum: Int32) -> Int32

@_extern(c, "gpio_pullup_en")
func gpio_pullup_en(_ gpioNum: Int32) -> Int32

@_extern(c, "gpio_set_level")
func gpio_set_level(_ gpioNum: Int32, _ level: UInt32) -> Int32

private let GPIO_MODE_INPUT: Int32 = 1  // hal/gpio_types.h
private let GPIO_MODE_OUTPUT: Int32 = 2 // hal/gpio_types.h

// Two wiring conventions — see the matching comment in KeyMatrix.swift.
//
// colsAreDriven == 0 (legacy): rows are push-pull outputs (idle HIGH),
// columns are inputs with pull-ups (idle HIGH, pressed reads LOW).
//
// colsAreDriven != 0 (ESP32-C6 smk_kbd board): columns are push-pull
// outputs (idle LOW), rows are inputs with pull-downs (idle LOW, pressed
// reads HIGH). This board's matrix is COL2ROW (diode anode at the
// switch/column side, cathode at the row side), so the driven line must be
// the column, not the row, for current to flow when a key closes.
func init_keyboard_pins(_ rows: UnsafePointer<Int32>, _ rowCount: Int32, _ cols: UnsafePointer<Int32>, _ colCount: Int32, _ colsAreDriven: Int32) {
    if colsAreDriven != 0 {
        // Rows: inputs with pull-downs (sense lines)
        for i in 0..<Int(rowCount) {
            let pin = rows[i]
            _ = gpio_reset_pin(pin)
            _ = gpio_set_direction(pin, GPIO_MODE_INPUT)
            _ = gpio_pulldown_en(pin)
            _ = gpio_pullup_dis(pin)
        }
        // Columns: push-pull outputs, idle LOW (strobe lines)
        for i in 0..<Int(colCount) {
            let pin = cols[i]
            _ = gpio_reset_pin(pin)
            _ = gpio_set_direction(pin, GPIO_MODE_OUTPUT)
            _ = gpio_set_level(pin, 0)
        }
    } else {
        // Rows: push-pull outputs, idle HIGH (strobe lines)
        for i in 0..<Int(rowCount) {
            let pin = rows[i]
            _ = gpio_reset_pin(pin)
            _ = gpio_set_direction(pin, GPIO_MODE_OUTPUT)
            _ = gpio_set_level(pin, 1)
        }
        // Columns: inputs with pull-ups (sense lines) — key press pulls to GND
        for i in 0..<Int(colCount) {
            let pin = cols[i]
            _ = gpio_reset_pin(pin)
            _ = gpio_set_direction(pin, GPIO_MODE_INPUT)
            _ = gpio_pullup_en(pin)
        }
    }
}

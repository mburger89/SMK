// RP2040 keyboard matrix pin setup.
//
// Counterpart to Sources/components/gpio_init.c (ESP32). Two wiring
// conventions are supported (see the matching comment in
// Sources/smk/KeyMatrix.swift) — which one applies is passed in from the
// shared JSON config via cols_are_driven:
//
//   - cols_are_driven == 0 (this board's default, unchanged): rows are
//     push-pull outputs, driven HIGH (inactive) at rest; scan() pulls a row
//     LOW to select it. Columns are inputs with pull-ups (active-low when a
//     key bridges row->col).
//   - cols_are_driven != 0: the opposite — columns are driven, rows are
//     sensed with pull-downs. Not used by the current RP2040 config, but
//     supported for parity with the ESP32-C6 board should a future RP2040
//     board share its COL2ROW wiring.
//
// After this runs, the SIO can drive/read levels directly, which is what the
// shared KeyMatrix.scan() does via ports/rp2040/GPIORegisters.swift.

#include "hardware/gpio.h"
#include <stdint.h>

void init_keyboard_pins(const int32_t *rows, int32_t row_count,
                        const int32_t *cols, int32_t col_count,
                        int32_t cols_are_driven) {
    if (cols_are_driven) {
        // Rows: inputs with pull-downs (sense lines)
        for (int32_t i = 0; i < row_count; i++) {
            uint32_t pin = (uint32_t)rows[i];
            gpio_init(pin);
            gpio_set_dir(pin, GPIO_IN);
            gpio_pull_down(pin);
        }
        // Columns: push-pull outputs, idle LOW (strobe lines)
        for (int32_t i = 0; i < col_count; i++) {
            uint32_t pin = (uint32_t)cols[i];
            gpio_init(pin);
            gpio_set_dir(pin, GPIO_OUT);
            gpio_put(pin, 0);
        }
    } else {
        // Rows: outputs, default HIGH (inactive). scan() pulls a row LOW to select it.
        for (int32_t i = 0; i < row_count; i++) {
            uint32_t pin = (uint32_t)rows[i];
            gpio_init(pin);
            gpio_set_dir(pin, GPIO_OUT);
            gpio_put(pin, 1);
        }
        // Columns: inputs with pull-ups (active-low when a key bridges row->col).
        for (int32_t i = 0; i < col_count; i++) {
            uint32_t pin = (uint32_t)cols[i];
            gpio_init(pin);
            gpio_set_dir(pin, GPIO_IN);
            gpio_pull_up(pin);
        }
    }
}

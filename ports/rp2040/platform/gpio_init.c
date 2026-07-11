// RP2040 keyboard matrix pin setup.
//
// Counterpart to Sources/componets/gpio_init.c (ESP32). Same electrical model:
//   - rows are push-pull outputs, driven HIGH (inactive) at rest
//   - columns are inputs with pull-ups; a pressed key pulls the column to GND
//
// After this runs, the SIO can drive/read levels directly, which is what the
// shared KeyMatrix.scan() does via ports/rp2040/GPIORegisters.swift.

#include "hardware/gpio.h"
#include <stdint.h>

void init_keyboard_pins(const int32_t *rows, int32_t row_count,
                        const int32_t *cols, int32_t col_count) {
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

#include "driver/gpio.h"

// Two wiring conventions — see the matching comment in Sources/smk/KeyMatrix.swift.
//
// cols_are_driven == 0 (legacy): rows are push-pull outputs (idle HIGH),
// columns are inputs with pull-ups (idle HIGH, pressed reads LOW).
//
// cols_are_driven != 0 (ESP32-C6 smk_kbd board): columns are
// push-pull outputs (idle LOW), rows are inputs with pull-downs (idle LOW,
// pressed reads HIGH). This board's matrix is COL2ROW (diode anode at the
// switch/column side, cathode at the row side), so the driven line must be
// the column, not the row, for current to flow when a key closes.
void init_keyboard_pins(int* rows, int row_count, int* cols, int col_count, int cols_are_driven) {
    if (cols_are_driven) {
        // Rows: inputs with pull-downs (sense lines)
        for (int i = 0; i < row_count; i++) {
            gpio_reset_pin(rows[i]);
            gpio_set_direction(rows[i], GPIO_MODE_INPUT);
            gpio_pulldown_en(rows[i]);
            gpio_pullup_dis(rows[i]);
        }
        // Columns: push-pull outputs, idle LOW (strobe lines)
        for (int i = 0; i < col_count; i++) {
            gpio_reset_pin(cols[i]);
            gpio_set_direction(cols[i], GPIO_MODE_OUTPUT);
            gpio_set_level(cols[i], 0);
        }
    } else {
        // Rows: push-pull outputs, idle HIGH (strobe lines)
        for (int i = 0; i < row_count; i++) {
            gpio_reset_pin(rows[i]);
            gpio_set_direction(rows[i], GPIO_MODE_OUTPUT);
            gpio_set_level(rows[i], 1);
        }
        // Columns: inputs with pull-ups (sense lines) — key press pulls to GND
        for (int i = 0; i < col_count; i++) {
            gpio_reset_pin(cols[i]);
            gpio_set_direction(cols[i], GPIO_MODE_INPUT);
            gpio_pullup_en(cols[i]);
        }
    }
}

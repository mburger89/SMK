#include "driver/gpio.h"

void init_keyboard_pins(int* rows, int row_count, int* cols, int col_count) {
    // Configure Rows as Outputs (Push-Pull)
    for(int i = 0; i < row_count; i++) {
        gpio_reset_pin(rows[i]);
        gpio_set_direction(rows[i], GPIO_MODE_OUTPUT);
        gpio_set_level(rows[i], 1); // Set high (inactive)
    }
    // Configure Columns as Inputs with Pull-Up resistors
    for(int i = 0; i < col_count; i++) {
        gpio_reset_pin(cols[i]);
        gpio_set_direction(cols[i], GPIO_MODE_INPUT);
        gpio_pullup_en(cols[i]); // Key press pulls this to GND
    }
}

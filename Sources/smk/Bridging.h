#include "sdkconfig.h"
#include "esp_log.h"
#include "esp_hidd.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "cJSON.h"

// BLE HID Functions
void init_ble_hid(void);
void send_keyboard_report(uint8_t modifier, uint8_t keycodes[6]);

// Wired HID Functions
void init_wired_link(void);
void send_wired_report(uint8_t modifier, uint8_t* keycodes);

// Logging
void kb_log(const char *msg);

// GPIO Matrix
void init_keyboard_pins(const int32_t* rows, int32_t row_count, const int32_t* cols, int32_t col_count);

// RGB LED chain (SK6812MINI-E via RMT) — chain wiring is serpentine, see
// RGBLighting.swift's ledChainIndex; this driver only knows raw chain
// position, not (row, col).
void led_strip_driver_init(int32_t gpio_num, int32_t num_leds);
void led_strip_set_pixel(int32_t index, uint8_t r, uint8_t g, uint8_t b);
void led_strip_refresh(void);
void led_strip_clear(void);

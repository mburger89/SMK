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

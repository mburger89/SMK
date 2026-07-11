// Bridging header for the RP2040 / Pico W build of SMK.
//
// The shared Swift sources (Sources/smk/{Main,LayerEngine,KeyMatrix}.swift) need:
//   - cJSON           (config / keymap parsing)
//   - libc            (strcmp / strncmp / atoi used by LayerEngine)
//   - the platform glue prototypes (also declared via @_extern in Swift, listed
//     here for clarity and C-side type checking).
//
// The ESP32 build uses Sources/smk/Bridging.h instead; this file is its RP2040
// counterpart and pulls in portable headers only (no ESP-IDF dependencies).

#pragma once

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#include "cJSON.h"

// --- Platform glue implemented in ports/rp2040/platform/*.c ---

// GPIO matrix (gpio_init.c)
void init_keyboard_pins(const int32_t *rows, int32_t row_count,
                        const int32_t *cols, int32_t col_count);

// USB HID — the "wired" path on RP2040 (usb_hid.c)
void init_wired_link(void);
void send_wired_report(uint8_t modifier, uint8_t *keycodes);

// BLE HID — real on Pico W, no-op stub on plain Pico (ble_hid.c)
void init_ble_hid(void);
void send_keyboard_report(uint8_t modifier, uint8_t *keycodes);

// Logging + cooperative delay (platform_glue.c)
void kb_log(const char *msg);
void vTaskDelay(uint32_t ticks); // shim: pumps USB then sleeps ~ticks ms

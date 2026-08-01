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

// GPIO Matrix — colsAreDriven selects which wiring convention to configure;
// see the comment in Sources/smk/KeyMatrix.swift.
void init_keyboard_pins(const int32_t* rows, int32_t row_count, const int32_t* cols, int32_t col_count, int32_t colsAreDriven);

// Board/connection-mode config (Sources/componets/smk_config.c), backed by
// Kconfig (main/Kconfig.projbuild) on this target.
int smk_has_wired_bridge(void);      // 1 if this board has working wired HID hardware
int smk_default_mode_is_wired(void); // 1 if firmware should boot into wired mode
int smk_has_rgb_backlight(void);     // 1 if a per-key RGB LED chain is wired up (opt-in)
int smk_rgb_gpio(void);              // GPIO driving that chain, if enabled

// RGB LED chain (SK6812MINI-E via RMT) — only referenced from Main.swift
// when compiled with -DSMK_RGB_AVAILABLE (ESP32-C6 build only; RP2040
// doesn't compile RGBLighting.swift at all). Chain wiring is serpentine,
// see RGBLighting.swift's ledChainIndex; this driver only knows raw chain
// position, not (row, col).
void led_strip_driver_init(int32_t gpio_num, int32_t num_leds);
void led_strip_set_pixel(int32_t index, uint8_t r, uint8_t g, uint8_t b);
void led_strip_refresh(void);
void led_strip_clear(void);

// Runtime keymap store (Sources/componets/smk_keymap_store.c, NVS-backed).
// See docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md.
int32_t smk_keymap_load(char *buf, uint32_t buf_size);
void smk_keymap_erase(void);
int32_t smk_keymap_begin_write(uint16_t total_len);
int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len);
int32_t smk_keymap_commit(uint32_t crc32);

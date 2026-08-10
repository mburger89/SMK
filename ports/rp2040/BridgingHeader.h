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

// USB HID — the "wired" path on RP2040 (usb_hid.c)
void init_wired_link(void);
void send_wired_report(uint8_t modifier, uint8_t *keycodes);

// BLE HID — real on Pico W, no-op stub on plain Pico (ble_hid.c)
void init_ble_hid(void);
void send_keyboard_report(uint8_t modifier, uint8_t *keycodes);

// Board/connection-mode config, logging, and the cooperative delay shim are
// now plain Swift — see ports/rp2040/PlatformConfig.swift. No C prototypes
// needed here (same-module Swift-to-Swift calls from Main.swift).

// Runtime keymap store (platform/smk_keymap_store.c, flash-backed). See
// docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md.
int32_t smk_keymap_load(char *buf, uint32_t buf_size);
void smk_keymap_erase(void);
int32_t smk_keymap_begin_write(uint16_t total_len);
int32_t smk_keymap_write_chunk(uint16_t offset, const uint8_t *data, uint16_t len);
int32_t smk_keymap_commit(uint32_t crc32);

// RGB backlight (platform/led_strip_driver.c) — only declared when this
// build compiles RGBLighting.swift in (SMK_TARGET_BOARD=smk_kbd_rp2040,
// via SMK_RGB_AVAILABLE in ports/rp2040/CMakeLists.txt). Mirrors
// Sources/smk/Bridging.h's ESP32 declarations; unlike ESP32 (Kconfig-driven,
// off by default), this board always has the hardware, so both are hardcoded
// — see led_strip_driver.c.
#ifdef SMK_RGB_AVAILABLE
int smk_has_rgb_backlight(void);
int smk_rgb_gpio(void);

void led_strip_driver_init(int32_t gpio_num, int32_t num_leds);
void led_strip_set_pixel(int32_t index, uint8_t r, uint8_t g, uint8_t b);
void led_strip_refresh(void);
void led_strip_clear(void);
#endif
